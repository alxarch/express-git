assign = require "object-assign"
g = require "nodegit"
{Reference, Repository, RepositoryInitOptions} = g
mime = require "mime-types"
Promise = require "bluebird"

{spawn, exec} = require "child_process"
exec = Promise.promisify exec
{which, test} = require "shelljs"
express = require "express"
{join} = require "path"
{createReadStream} = require "fs"
{PassThrough, Transform} = require "stream"
{createUnzip} = require "zlib"

defaults =
	auto_init: yes
	serve_static: yes
	authorize: (action, params, req) -> yes
	repo_init_options: (repo, req) -> null
	only_bare: yes
	git_project_root: null
	git_executable: which "git"


pkt_line = (line) ->
	unless line instanceof Buffer
		line = new Buffer "#{line}"
	prefix = new Buffer "0000#{line.length.toString 16}".substr -4, 4
	Buffer.concat [prefix, line]

class GitObjectReadStream extends Transform
	_transform: (chunk, encoding, callback) ->
		unless @header
			for c, i in chunk when c is 0
				break
			@header = "#{chunk.slice 0, i}"
			[@type, @size] = @header.split /\s+/
			@emit "header", @type, @size
			chunk = chunk.slice i + 1
		@push chunk
		callback()

stream_blob = (repo, oid) ->
	p = new Promise (resolve, reject) ->
		loose = join repo.path(), "objects", oid[0..1], oid[2..]
		stream = new GitObjectReadStream()
		stream.on "header", -> resolve stream
		stream.on "error", reject
		try
			createReadStream loose
			.pipe createUnzip()
			.pipe stream
		catch err
			reject err
		return
	p.catch ->
		g.Blob.lookup repo, g.Oid.fromSting oid
		.then (blob) ->
			data = blob.rawcontent()
			blob.free()
			stream = new PassThrough
			stream.type = "blob"
			stream.size = data.length
			new Promise (resolve, reject) ->
				resolve stream
				stream.write data
				stream.end()


UnhandledError = (err) -> not (err.statusCode or null)?

module.exports = (options={}) ->

	opt = assign {}, defaults, options

	GIT_PROJECT_ROOT = "#{opt.git_project_root or ''}"
	GIT_EXEC = opt.git_executable
	{BARE, NO_REINIT, MKDIR, MKPATH} = Repository.INIT_FLAG
	REPO_INIT_FLAGS = BARE | NO_REINIT | MKPATH | MKDIR

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

	open_repo = (repo_path, auto_init) ->
		git_dir = join GIT_PROJECT_ROOT, repo_path
		Promise.resolve Repository.open git_dir
		.catch (err) ->
			if auto_init and not test "-e", git_dir
				{repo_init_options} = opt
				if typeof repo_init_options is "function"
					repo_init_options = repo_init_options repo_path, req

				unless repo_init_options instanceof RepositoryInitOptions
					repo_init_options = new RepositoryInitOptions()

				repo_init_options.flags |= REPO_INIT_FLAGS
				repo_init_options.initialHead ?= "master"

				Repository.initExt git_dir, repo_init_options
			else
				null
		.catch (err) -> null
		.then (repo) ->
			unless repo instanceof Repository
				throw new NotFoundError "Repository #{repo_path} not found"

			if opt.only_bare and not repo.isBare()
				throw new BadRequestError "Repository #{repo_path} is not bare"
			repo

	# git_http_backend.post "/:repo_path(*).git/git-:service(receive-pack|upload-pack)", (req, res, next) ->
	git_http_backend.post /^\/(.*)\.git\/git-(receive-pack|upload-pack)$/, (req, res, next) ->
		Promise.join req.params[0], req.params[1], (repo_path, service) ->
			authorize service, {repo_path}, req
			.then -> open_repo repo_path, opt.auto_init
			.then (repo) ->
				res.set 'Content-Type', "application/x-git-#{service}-result"
				new Promise (resolve, reject) ->
					args = [service, '--stateless-rpc', repo.path()]
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

	git_http_backend.get /^\/(.*)\.git\/info\/refs$/, (req, res, next) ->
		Promise.join req.query.service, req.params[0], (service, repo_path) ->
			unless service in ["git-upload-pack", "git-receive-pack"]
				throw new BadRequestError "Invalid service #{service}"
			service = service.replace /^git-/, ''
			authorize service, {repo_path} , req
			.then -> open_repo repo_path, opt.auto_init
			.then (repo) ->
				res.set 'Content-Type', "application/x-#{service}-advertisement"
				exec "#{GIT_EXEC} #{service} --stateless-rpc --advertise-refs #{repo.path()}"
			.spread (stdout, stderr) ->
				res.write pkt_line "# service=#{service}\n0000"
				res.write stdout
				res.end()
				next()
		.catch UnhandledError, (err) -> throw new ServerError err.message
		.catch next

	serve_static = (req, res, next) ->

		[repo_path, refname, path] = req.params
		refname ?= "HEAD"
		free = []
		repo = null
		authorize "raw", {repo_path, refname, path} , req
		.then -> open_repo repo_path, no
		.then (r) ->
			repo = r
			if refname is "HEAD"
			then repo.head()
			else repo.getReference refname
		.catch UnhandledError, -> throw new NotFoundError "Reference #{refname} not found"
		.then (ref) -> g.Commit.lookup repo, ref.target()
		.catch UnhandledError, -> throw new NotFoundError "Commit not found"
		.tap (commit) -> free.push commit
		.then (commit) -> commit.getTree()
		.tap (tree) -> free.push tree
		.then (tree) -> tree.entryByPath path
		.catch UnhandledError, -> throw new NotFoundError "Entry not found"
		.then (entry) ->
			unless entry.isBlob()
				throw new BadRequestError "Path doesn't lead to a BLOB"
			stream_blob repo, entry.sha()
		.then (blob) ->
			res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
			res.set "Content-Length", blob.size
			blob.pipe res
		.finally -> (o.free() for o in free)
		.catch UnhandledError, (err) -> throw new ServerError err.message
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
