{a2o, spawn, exec, assign, freeze, socket, pkt_line} = require "./helpers"
{NotFoundError, BadRequestError, UnauthorizedError} = require "./errors"
mime = require "mime-types"
Promise = require "bluebird"

{mkdir, which, test} = require "shelljs"
express = require "express"
_path = require "path"
g = require "./ezgit"
uuid = require "uuid"
moment = require "moment"

defaults =
	auto_init: yes
	pattern: /.*/
	serve_static: yes
	authorize: null
	init_options: null
	git_project_root: null
	git_executable: which "git"
	hooks_socket: socket()
	pre_receive: null
	post_receive: null
	max_age: 365 * 24 * 60 * 60

UnhandledError = (err) -> not (err.status or null)?

module.exports = (options={}) ->

	options = assign {}, defaults, options

	GIT_PROJECT_ROOT = "#{options.git_project_root}"
	GIT_EXEC = options.git_executable
	GIT_HOOK_SOCKET = options.hooks_socket

	# Initialize the hooks server
	hooks = require("./hook-server") GIT_HOOK_SOCKET

	# Setup the EXPRESS_GIT_HOOK env var passed to hook scripts
	hook = require.resolve './hook'
	EXPRESS_GIT_HOOK = [hook]
	# Allow ".coffee" extensions for development
	if ".coffee" is _path.extname hook
		EXPRESS_GIT_HOOK.unshift require.resolve "coffee-script/register"
	EXPRESS_GIT_HOOK = EXPRESS_GIT_HOOK.join _path.delimiter

	git_http_backend = express()
	git_http_backend.disable "etag"

	unless options.pattern instanceof RegExp
		options.pattern = new RegExp "#{options.pattern}"
	noCache = (req, res, next) ->
			res.set
				'Pragma': 'no-cache'
				'Expires': (new Date '1900').toISOString()
				'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			next()

	# Middleware prologue: setup cache headers and req.git object
	git_http_backend.use (req, res, next) ->
		req.git = freeze project_root: GIT_PROJECT_ROOT
		next()

	matchRepo = (req, res, next) ->
		m = "#{req.git.reponame}".match options.pattern
		if m?
			req.git = freeze req.git, repoargs: freeze a2o m[1..]
			next()
		else
			next new NotFoundError "Repository not found"

	authPromise =
		if typeof options.auth is "function"
		then Promise.promisify auth
		else -> Promise.resolve()

	authorize = (req, res, next) ->
		authPromise req, res
		.then -> next()
		.catch UnhandledError, (err) ->
			throw new UnauthorizedError err.message or "#{err}"
		.catch next

	attachRepo = (init) ->
		(req, res, next) ->
			(if init then openOrInitRepo else openRepo) req
			.catch (err) -> null
			.then (repo) ->
				unless repo?
					throw new NotFoundError "Repository #{req.git.reponame} not found"
				req.git = freeze req.git, {repo}
				next()
			.catch next

	openOrInitRepo = (req) ->
		git_dir = _path.join GIT_PROJECT_ROOT, req.git.reponame

		openRepo req
		.catch (err) ->
			if options.auto_init and not test "-e", git_dir
				# Temporarily override req.git.service
				restore = req.git
				req.git = freeze req.git, service: "init"
				authorize req, res
				.then -> initOptions req
				.then (init) -> g.Repository.init git_dir, init
			else
				null


	openRepo = (req) ->
		git_dir = _path.join GIT_PROJECT_ROOT, req.git.reponame
		g.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]

	initOptions = (req) ->
		template = _path.resolve __dirname, '..', 'templates/'
		description = """
			#{req.git.reponame}
			============

			This repository was created on #{new Date()} by express-git.
			"""

		p = Promise.resolve do ->
			{init_options} = options
			switch typeof init_options
				when "function"
					init_options req
				when "object"
					init_options
				else
					{}
		p.then (options) ->
			assign {template, description}, options

	# Main push/pull services
	# via git receive-pack/upload-pack commands
	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/,
		noCache
		(req, res, next) ->
			[reponame, service] = req.params
			req.git = freeze req.git, {reponame, service}

			next()
		matchRepo
		authorize
		attachRepo options.auto_init
		(req, res, next) ->
			{repo, service} = req.git
			res.set 'Content-Type', "application/x-git-#{service}-result"
			hooks.then (hooks) ->
				env = {}
				if service is "receive-pack"
					GIT_HOOK_ID = uuid.v4()
					env = {EXPRESS_GIT_HOOK, GIT_HOOK_SOCKET, GIT_HOOK_ID}
					{post_receive, pre_receive} = options

					if typeof pre_receive is "function"
						# Respond only after pre-receive hook
						hooks.once "#{GIT_HOOK_ID}:pre-receive", (changes, callback) ->
							req.git = freeze req.git, {changes}
							pre_receive req, res, callback

					if typeof post_receive is "function"
						hooks.once "#{GIT_HOOK_ID}:post-receive", (changes, callback) ->
							req.git = freeze req.git, {changes}
							post_receive req, res, callback

				args = [service, '--stateless-rpc', repo.path()]
				stdio = [req, res, 'pipe']
				spawn GIT_EXEC, args, {env, stdio}
			.then -> repo.free()
			.catch next

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	git_http_backend.get /\/(.*)\.git\/info\/refs/,
		noCache
		(req, res, next) ->
			reponame = req.params[0]
			service = req.query.service
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			req.git = freeze req.git, {reponame, service}
			next()
		matchRepo
		authorize
		attachRepo options.auto_init
		(req, res, next) ->
			{service, reponame, repo} = req.git
			res.set 'Content-Type', "application/x-git-#{service}-advertisement"
			res.write pkt_line "# service=git-#{service}\n0000"
			args = [service, '--stateless-rpc', '--advertise-refs', repo.path()]
			stdio = ['ignore', res, 'pipe']
			spawn GIT_EXEC, args, {stdio}
			.then -> repo.free()
	# Direct access to blobs in repos
	serve_static_pattern = ///
		^/
		(.*)\.git  # Repo path MUST end with .git
		/blob/
		(?:(.*):)?  # commit-ish (default: HEAD) ends with :
	   			    # Having it in path allows relative path resolutions
		(.*)        # Rest of the path is used to resolve a file in workdir
		$
		///

	serve_static = [
		(req, res, next) ->
			[reponame, rev, path] = req.params

			service = "blob"
			rev ?= "HEAD"
			req.git = freeze req.git, {reponame, path, service, rev}
			next()
		matchRepo
		authorize
		attachRepo no
		(req, res, next) ->
			{rev, path, repo} = req.git
			repo.find {rev, path}
			.catch (err) ->
				throw new NotFoundError "Blob not found"
			.then (object) ->
				unless object.type() is g.Object.TYPE.BLOB
					throw new NotFoundError "Blob not found"
				id = "#{object.id()}"

				if id is req.headers['if-none-match']
					res.status 304
					res.end()
				else
					g.Blob.lookup repo, object.id()
					.then (blob) ->
						{max_age} = options
						res.set "Etag", id
						res.set "Cache-Control", "private, max-age=#{max_age}, no-transform, must-revalidate"
						res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
						res.set "Content-Length", blob.rawsize()
						res.write blob.content()
						res.end()
						blob.free()
						object.free()
						repo.free()
			.catch next
	]

	if options.serve_static
		git_http_backend.get serve_static_pattern, serve_static

	git_http_backend
