assign = require "object-assign"
{Reference, Repository, RepositoryInitOptions} = require "nodegit"

{spawn, exec} = require "child_process"
{which, test} = require "shelljs"
express = require "express"
{join} = require "path"

defaults =
	auto_init: yes
	repo_init_options: (repo, req) -> null
	only_bare: yes
	git_project_root: null
	git_executable: which "git"

pkt_line = (line) ->
	unless line instanceof Buffer
		line = new Buffer "#{line}"
	prefix = new Buffer "0000#{line.length.toString 16}".substr -4, 4
	Buffer.concat [prefix, line]


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

	git_http_backend.post "/:repo_path(*)/git-:service(receive-pack|upload-pack)", (req, res, next) ->
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

	git_http_backend.get "/:repo_path(*)/info/refs", (req, res, next) ->
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

	git_http_backend.use (err, req, res, next) ->
		if err.statusCode
			res.status err.statusCode
			res.text err.statusMessage or err.message
		else
			next err

	git_http_backend

class ServerError extends Error
	statusCode: 500
class NotFoundError extends Error
	statusCode: 404
class BadRequestError extends Error
	statusCode: 400
