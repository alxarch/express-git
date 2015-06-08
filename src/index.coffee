{a2o, spawn, exec, assign, freeze, socket, pkt_line} = require "./helpers"
mime = require "mime-types"
Promise = require "bluebird"

{ln, mkdir, which, test} = require "shelljs"
express = require "express"
_path = require "path"
g = require "ezgit"
uuid = require "uuid"

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

UnhandledError = (err) -> not (err.statusCode or null)?

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

	no_cache = (req, res, next) ->
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		next()

	# Middleware prologue: setup cache headers and req.git object
	git_http_backend.use (req, res, next) ->

		req.git = freeze project_root: GIT_PROJECT_ROOT
		next()

	repomatch = (req) ->
		m = "#{req.git.reponame}".match options.pattern
		unless m?
			throw new NotFoundError "Repository not found"
		req.git = freeze req.git, repoargs: freeze a2o m[1..]

	authorize =
		if typeof options.authorize is "function"
		then -> Promise.resolve()
		else
			Promise.promisify options.authorize
			.catch (err) ->
				msg = err?.message or err or "Not Authorized"
				throw new UnauthorizedError "#{msg}"

	open_repo = (req, res, init=options.auto_init) ->
		git_dir = _path.join GIT_PROJECT_ROOT, req.git.reponame
		g.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if init and not test "-e", git_dir
				# Temporarily override req.git.service
				restore = req.git
				req.git = freeze req.git, service: "init"
				authorize req, res
				.then ->
					req.git = restore
					init_options req
				.then (options) ->
					g.Repository.init git_dir, options
			else
				null
		.catch (err) ->
			null
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{req.git.reponame} not found"
			repo

	init_options = (req) ->
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
	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/, no_cache, (req, res, next) ->
		[reponame, service] = req.params
		req.git = freeze req.git, {reponame, service}
		repomatch req
		res.set 'Content-Type', "application/x-git-#{service}-result"

		authorize req, res
		.then ->
			repo = open_repo req, res
			Promise.join repo, hooks, (repo, hooks) ->
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
		.catch next

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	git_http_backend.get /\/(.*)\.git\/info\/refs/, no_cache, (req, res, next) ->

		Promise.join req.query.service, req.params[0], (service, reponame) ->
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			req.git = freeze req.git, {service, reponame}
			repomatch req
			authorize req, res
			.then -> open_repo req, res
			.then (repo) ->
				res.set 'Content-Type', "application/x-git-#{service}-advertisement"
				res.write pkt_line "# service=git-#{service}\n0000"
				args = [service, '--stateless-rpc', '--advertise-refs', repo.path()]
				stdio = ['ignore', res, 'pipe']
				spawn GIT_EXEC, args, {stdio}
		.catch next

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

	serve_static = (req, res, next) ->
		[reponame, rev, path] = req.params

		service = "raw"
		rev ?= "HEAD"
		req.git = freeze req.git, {reponame, path, service}
		repomatch req
		authorize req, res
		.then -> open_repo req, res, no
		.then (repo) ->
			repo.find {rev, path}
			.catch (err) ->
				# console.error err.stack
				throw new NotFoundError "Blob not found"
			.then (object) ->

				unless object.type() is g.Object.TYPE.BLOB
					throw new NotFoundError "Blob not found"

				etag = "#{object.id()}"

				if etag is req.headers['if-none-match']
					res.status 304
					res.end()
				else
					repo.createReadStream object
					.then ({stream, size}) ->
						res.set "Etag", "#{etag}"
						res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
						res.set "Content-Length", size
						stream.pipe res

		.catch next

	if options.serve_static
		git_http_backend.get serve_static_pattern, serve_static

	git_http_backend.use (err, req, res, next) ->
		if err.statusCode
			res.status err.statusCode
			res.set "Content-Type", "text/plain"
			res.send err.message
			res.end()
		else
			next err

	git_http_backend

class ServerError extends Error
	constructor: (@message, @statusCode=500) -> super

class NotFoundError extends Error
	constructor: (@message, @statusCode=404) -> super

class BadRequestError extends Error
	constructor: (@message, @statusCode=400) -> super

class UnauthorizedError extends Error
	constructor: (@message, @statusCode=401) -> super
