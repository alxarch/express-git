{assign, freeze, socket, pkt_line} = require "./helpers"
mime = require "mime-types"
Promise = require "bluebird"

{spawn, exec} = require "child_process"
exec = Promise.promisify exec
{ln, mkdir, which, test} = require "shelljs"
express = require "express"
_path = require "path"
ezgit = require "./ezgit"
uuid = require "uuid"

defaults =
	auto_init: yes
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

	hooks = require("./hook-server") GIT_HOOK_SOCKET

	hook = require.resolve './hook'
	EXPRESS_GIT_HOOK = [hook]
	if ".coffee" is _path.extname hook
		EXPRESS_GIT_HOOK.unshift require.resolve "coffee-script/register"
	EXPRESS_GIT_HOOK = EXPRESS_GIT_HOOK.join _path.delimiter

	git_http_backend = express()
	git_http_backend.disable "etag"


	git_http_backend.use (req, res, next) ->
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		req.git = freeze project_root: GIT_PROJECT_ROOT
		next()


	authorize = (req, res) ->
		new Promise (resolve ,reject) ->
			callback = (err) -> 
				if err
					reject new UnauthorizedError (err?.message or err or "Not Authorized")
				else
					resolve()

			if typeof options.authorize is "function"
				options.authorize req, res, callback
			else
				callback()

	open_repo = (req, res, init=null) ->
		init ?= options.auto_init
		git_dir = _path.join GIT_PROJECT_ROOT, req.git.reponame
		ezgit.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if init and not test "-e", git_dir
				restore = req.git
				# Temporarily override req.git.service
				req.git = freeze req.git, service: "init"
				authorize req, res
				.then ->
					req.git = restore
					init_options req
				.then (options) ->
					ezgit.Repository.init git_dir, options
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

	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/, (req, res, next) ->
		[reponame, service] = req.params
		req.git = freeze req.git, {reponame, service}

		authorize req, res
		.then ->
			repo = open_repo req, res
			Promise.join repo, hooks, (repo, hooks) ->
				args = [service, '--stateless-rpc', repo.path]
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

				new Promise (resolve, reject) ->
					git = spawn GIT_EXEC, args, {env}
					res.set 'Content-Type', "application/x-git-#{service}-result"
					git.stdout.pipe res
					git.stderr.pipe process.stderr
					git.on "exit", (code) ->
						if code is 0
							resolve()
						else
							reject new ServerError "Exit code #{code} returned from #{service}"

					# GO git 'em!
					req.pipe git.stdin

		.then -> next()
		.catch UnhandledError, (err) ->
			console.error err.stack
			new ServerError err.message
		.catch next

	git_http_backend.get /\/(.*)\.git\/info\/refs/, (req, res, next) ->

		Promise.join req.query.service, req.params[0], (service, reponame) ->
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			req.git = freeze req.git, {service, reponame}
			authorize req, res
			.then -> open_repo req, res
			.then (repo) ->
				res.set 'Content-Type', "application/x-git-#{service}-advertisement"
				exec "#{GIT_EXEC} #{service} --stateless-rpc --advertise-refs #{repo.path}"
			.spread (stdout, stderr) ->
				res.write pkt_line "# service=git-#{service}\n0000"
				res.write stdout
				process.stderr.write stderr
				res.end()
				next()
		.catch UnhandledError, (err) ->
			console.error err.stack
			throw new ServerError err.message
		.catch next

	serve_static = (req, res, next) ->
		[reponame, ref, path] = req.params
		service = "raw"
		ref ?= "HEAD"
		req.git = freeze req.git, {reponame, ref, path, service}
		authorize req, res
		.then -> open_repo req, res, no
		.then (repo) -> repo.findByPath path, {ref}
		.then (object) ->
			unless object.type is "blob"
				throw new BadRequestError "Path doesn't lead to a BLOB"
			object.getReadStream()
		.then ({stream, size}) ->
			res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
			res.set "Content-Length", size
			stream.pipe res
		.catch next

	if options.serve_static
		git_http_backend.get ///
			^/
			(.*)\.git        # Repo path MUST end with .git
			(?:/(refs/.*))?  # ref name is optional (default: HEAD)
							 # Having it in path allows relative paths
			/~raw/           # We need ~ to mark the end of a valid ref name
			(.*)             # Rest of the path is used to resolve a file in workdir
			$
			///, serve_static

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
