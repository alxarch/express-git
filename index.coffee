assign = require "object-assign"
g = require "nodegit"
{Reference, Repository, RepositoryInitOptions} = g
mime = require "mime-types"
{resolve} = require "bluebird"

{spawn, exec} = require "child_process"
{which, test} = require "shelljs"
express = require "express"
{join} = require "path"
{createReadStream} = require "fs"
{PassThrough, Transform} = require "stream"
{createUnzip} = require "zlib"

defaults =
	auto_init: yes
	serve_static: yes
	repo_init_options: (repo, req) -> null
	only_bare: yes
	git_project_root: null
	git_executable: which "git"

asref = (name) -> if name and Reference.isValidName name then name else "HEAD"
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

module.exports = (options={}) ->

	opt = assign {}, defaults, options

	GIT_PROJECT_ROOT = "#{opt.git_project_root or ''}"
	GIT_EXEC = opt.git_executable
	{BARE, NO_REINIT, MKDIR, MKPATH} = Repository.INIT_FLAG
	REPO_INIT_FLAGS = BARE | NO_REINIT | MKPATH | MKDIR

	git_http_backend = new express.Router()

	git_http_backend.use (req, res, next) ->
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		next()

	git_http_backend.param "repo_path", (req, res, next, repo_path) ->
		git_dir = join GIT_PROJECT_ROOT, repo_path
		Repository.open git_dir
		.catch (err) ->
			return null unless opt.auto_init and not test "-e", git_dir

			{repo_init_options} = opt
			if typeof repo_init_options is "function"
				repo_init_options = repo_init_options repo_path, req

			unless repo_init_options instanceof RepositoryInitOptions
				repo_init_options = new RepositoryInitOptions()

			repo_init_options.flags |= REPO_INIT_FLAGS
			repo_init_options.initialHead ?= "master"

			Repository.initExt git_dir, repo_init_options
		.then (repo) ->
			unless repo instanceof Repository
				throw new NotFoundError "Repository #{repo_path} not found"
			if opt.only_bare and not repo.isBare()
				throw new BadRequestError "Repository #{repo_path} is not bare"
			req.repo = repo
			next()
		.catch next

	git_http_backend.post "/:repo_path(*).git/git-:service(receive-pack|upload-pack)", (req, res, next) ->
		[service] = req.params
		res.set 'Content-Type', "application/x-git-#{service}-result"
		args = [service, '--stateless-rpc', req.repo.path()]
		git = spawn GIT_EXEC, args
		req.pipe git.stdin
		git.stdout.pipe res
		git.stderr.pipe process.stderr
		git.on "exit", (code) ->
			if code is 0
				next()
			else
				next new ServerError "Exit code #{code} returned from #{service}"

	git_http_backend.get "/:repo_path(*).git/info/refs", (req, res, next) ->
		{service} = req.query
		res.set 'Content-Type', "application/x-#{service}-advertisement"
		unless service in ["git-upload-pack", "git-receive-pack"]
			return next new BadRequestError "Invalid service #{service}"

		res.write pkt_line "# service=#{service}\n0000"
		cmd = "#{GIT_EXEC} #{service.replace /^git-/, ''} --stateless-rpc --advertise-refs #{req.repo.path()}"
		exec cmd, (err, stdout, stderr) ->
			if err
				next new ServerError err.message
			else
				res.write stdout
				res.end()
				next()

	UnhandledError = (err) -> (err.statusCode or null)?

	serve_static = (req, res, next) ->
		{repo} = req
		[_, path] = req.params

		free = []
		refname = asref req.query?.ref 
		resolve refname
		.then (refname) -> if refname is "HEAD" then repo.head() else repo.getReference refname
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
		git_http_backend.get "/:repo_path(*).git/raw/:path(*)", serve_static

	git_http_backend

class ServerError extends Error
	statusCode: 500
class NotFoundError extends Error
	statusCode: 404
class BadRequestError extends Error
	statusCode: 400
