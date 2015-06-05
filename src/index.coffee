assign = require "object-assign"
mime = require "mime-types"
Promise = require "bluebird"

{spawn, exec} = require "child_process"
exec = Promise.promisify exec
{which, test} = require "shelljs"
express = require "express"
path = require "path"
ezgit = require "./ezgit"

defaults =
	auto_init: yes
	serve_static: yes
	authorize: (service, params, req) -> yes
	init_options: (repo, req) -> {}
	git_project_root: null
	git_executable: which "git"


pkt_line = (line) ->
	unless line instanceof Buffer
		line = new Buffer "#{line}"
	prefix = new Buffer "0000#{line.length.toString 16}".substr -4, 4
	Buffer.concat [prefix, line]

UnhandledError = (err) -> not (err.statusCode or null)?

module.exports = (options={}) ->

	opt = assign {}, defaults, options

	GIT_PROJECT_ROOT = "#{opt.git_project_root or ''}"
	GIT_EXEC = opt.git_executable

	git_http_backend = express()
	git_http_backend.disable "etag"

	git_http_backend.use (req, res, next) ->
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		next()
	
	authorize = (service, params, req) ->
		if typeof opt.authorize is "function"
			Promise.resolve opt.authorize service, params, req
			.catch UnhandledError, (err) ->
				throw new UnauthorizedError err.message or "Not authorized"
		else
			Promise.resolve null

	open_repo = (repo_path, req) ->
		git_dir = path.join GIT_PROJECT_ROOT, repo_path
		ezgit.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if opt.auto_init and not test "-e", git_dir
				authorize "init", {repo_path}, req
				.then -> ezgit.Repository.init git_dir, init_options repo_path, req
			else
				null
		.catch (err) -> null
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{repo_path} not found"
			repo

	init_options = (repo_path, req) ->
		unless opt.auto_init
			return null
		if typeof opt.init_options is "function"
			opt.init_options repo_path, req
		else
			opt.init_options or {}

	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/, (req, res, next) ->
		Promise.join req.params[0], req.params[1], (repo_path, service) ->
			authorize service, {repo_path}, req
			.then -> open_repo repo_path, req
			.then (repo) ->
				res.set 'Content-Type', "application/x-git-#{service}-result"
				new Promise (resolve, reject) ->
					args = [service, '--stateless-rpc', repo.path]
					git = spawn GIT_EXEC, args
					req.pipe git.stdin
					git.stdout.pipe res
					git.stderr.pipe process.stderr
					git.on "exit", (code) ->
						if code is 0
							resolve()
						else
							reject new ServerError "Exit code #{code} returned from #{service}"
			.then -> next()
		.catch UnhandledError, (err) -> new ServerError err.message
		.catch next

	git_http_backend.get /\/(.*)\.git\/info\/refs/, (req, res, next) ->
		Promise.join req.query.service, req.params[0], (service, repo_path) ->
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			authorize service, {repo_path} , req
			.then -> open_repo repo_path, req
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
		authorize "raw", {repo_path, refname, path} , req
		.then -> open_repo repo_path, no
		.then (repo) -> repo.find path, ref: refname
		.then (object) ->
			unless object.type is "blob"
				throw new Error "Path doesn't lead to a BLOB"
			object.getReadStream()
		.catch (err) -> throw new NotFoundError err.message
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
