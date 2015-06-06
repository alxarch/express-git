assign = require "object-assign"
mime = require "mime-types"
Promise = require "bluebird"

{spawn, exec} = require "child_process"
exec = Promise.promisify exec
{ln, mkdir, which, test} = require "shelljs"
express = require "express"
path = require "path"
ezgit = require "./ezgit"
uuid = require "uuid"
helpers = require "./helpers"

defaults =
	auto_init: yes
	serve_static: yes
	authorize: null
	init_options: null
	git_project_root: null
	git_executable: which "git"
	hooks_socket: helpers.socket()
	pre_receive: null
	post_receive: null

pkt_line = (line) ->
	unless line instanceof Buffer
		line = new Buffer "#{line}"
	prefix = new Buffer "0000#{line.length.toString 16}".substr -4, 4
	Buffer.concat [prefix, line]

UnhandledError = (err) -> not (err.statusCode or null)?

module.exports = (options={}) ->

	opt = assign {}, defaults, options

	GIT_PROJECT_ROOT = "#{opt.git_project_root}"
	GIT_EXEC = opt.git_executable
	GIT_HOOK_SOCKET = opt.hooks_socket

	hooks = require("./hook-server") GIT_HOOK_SOCKET

	hook = require.resolve './hook'
	EXPRESS_GIT_HOOK = [hook]
	if ".coffee" is path.extname hook
		EXPRESS_GIT_HOOK.unshift require.resolve "coffee-script/register"
	EXPRESS_GIT_HOOK = EXPRESS_GIT_HOOK.join path.delimiter

	git_http_backend = express()
	git_http_backend.disable "etag"

	git_http_backend.use (req, res, next) ->
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		next()

	authorize = (req, res, params) ->
		new Promise (resolve ,reject) ->
			callback = (err) -> 
				if err
					reject new UnauthorizedError (err?.message or err or "Not Authorized")
				else
					resolve()

			if typeof opt.authorize is "function"
				opt.authorize req, res, callback, params
			else
				callback()

	open_repo = (req, res, repo_path, init) ->
		git_dir = path.join GIT_PROJECT_ROOT, repo_path
		ezgit.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if init and not test "-e", git_dir
				authorize req, res,
					service: "init"
					repo_path: "repo_path"
				.then ->
					init_options repo_path, req
				.then (initopt) ->
					ezgit.Repository.init git_dir, initopt
			else
				null
		.catch (err) ->
			null
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{repo_path} not found"
			repo

	init_options = (repo_path, req) ->
		template = path.resolve __dirname, '..', 'templates/'
		description = """
			#{repo_path}
			============

			This repository was created on #{new Date()} by express-git.
			"""

		p = new Promise (resolve) ->
			if typeof opt.init_options is "function"
				resolve opt.init_options repo_path, req
			else
				resolve opt.init_options or {}
		p.then (options) ->
			assign {template, description}, options

	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/, (req, res, next) ->
		[repo_path, service] = req.params
		authorize req, res, {service, repo_path}
		.then ->
			repo = open_repo req, res, repo_path, opt.auto_init
			Promise.join repo, hooks, (repo, hooks) ->
				args = [service, '--stateless-rpc', repo.path]
				env = {}
				if service is "receive-pack"
					GIT_HOOK_ID = uuid.v4()
					env = {EXPRESS_GIT_HOOK, GIT_HOOK_SOCKET, GIT_HOOK_ID}

					if typeof opt.pre_receive is "function"
						# Respond only after pre-receive hook
						hooks.once "#{GIT_HOOK_ID}:pre-receive", (changes, callback) ->
							opt.pre_receive req, res, callback, {changes, repo_path}
					if typeof opt.post_receive is "function"
						hooks.once "#{GIT_HOOK_ID}:post-receive", (changes, callback) ->
							opt.post_receive req, res, callback, {changes, repo_path}

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

		Promise.join req.query.service, req.params[0], (service, repo_path) ->
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			authorize req, res, {service, repo_path}
			.then -> open_repo req, res, repo_path, opt.auto_init
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
		[repo_path, refname, path] = req.params
		refname ?= "HEAD"
		service = "raw"
		authorize req, res, {refname, repo_path, path, service}
		.then -> open_repo req, res, repo_path, no
		.then (repo) -> repo.find path, ref: refname
		.then (object) ->
			unless object.type is "blob"
				throw new BadRequestError "Path doesn't lead to a BLOB"
			object.getReadStream()
		.then ({stream, size}) ->
			res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
			res.set "Content-Length", size
			stream.pipe res
		.catch next

	if opt.serve_static
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
