{a2o, spawn, assign, freeze} = require "./helpers"
{NonHttpError, NotFoundError, BadRequestError, UnauthorizedError} = require "./errors"
Promise = require "bluebird"

{mkdir, test} = require "shelljs"
express = require "./express"
_path = require "path"

module.exports = expressGit = {}
expressGit.git = git = require "./ezgit"
expressGit.errors = require "./errors"
expressGit.gitHttpBackend = require "./services/git_http_backend"
expressGit.serveBlob  = require "./services/serve_blob"

EXPRESS_GIT_DEFAULTS =
	git_http_backend: yes
	serve_static: yes
	auto_init: yes
	pattern: /.*/
	auth: null
	services: {}

expressGit.serve = (root, options) ->
	options = assign {}, options, EXPRESS_GIT_DEFAULTS
	unless options.pattern instanceof RegExp
		options.pattern = new Regexp "#{options.pattern or '.*'}"
	unless typeof options.auth is "function"
		options.auth = (req, res, next) -> next()
	
	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_TEMPLATE_PATH = _path.resolve __dirname, "..", "templates"
	GIT_INIT_OPTIONS = freeze options.auto_init, template: GIT_TEMPLATE_PATH
	
	app = express()
	
	NODEGIT_OBJECTS = []
	cleanup = NODEGIT_OBJECTS.push.bind NODEGIT_OBJECTS

	app.disable "etag"

	app.use (req, res, next) ->
		req.git = freeze req.git, {cleanup}
		next()


	app.param "git_service", (req, res, next, service) ->
		if service is "info/refs" and req.method is "GET"
			{service} = req.query
			if service in ["git-upload-pack", "git-receive-pack"]
				service = service.replace "git-", ""
			else
				return next new BadRequestError "Invalid service #{service}"

		cb = (err) ->
			if err
				next if err.status then err else new UnauthorizedError err.message
			else
				req.git = freeze req.git, {service}
				next()
		options.auth req, res, cb, service

	app.param "git_repo", (req, res, next, reponame) ->
		reponame = reponame.replace /\.git$/, ''
		m = "#{reponame}".match options.pattern
		unless m?
			return next new NotFoundError "Repository not found"
		git_dir = _path.join GIT_PROJECT_ROOT, reponame
		Promise.resolve git.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if options.auto_init and not test "-e", git_dir
				git.Repository.init git_dir, GIT_INIT_OPTIONS
			else
				null
		.catch -> null
		.tap cleanup
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{git_repo} not found"
			# TODO: use path-to-regexp for named params
			repo.params = freeze a2o m[1..]
			repo.name = reponame
			req.git = freeze req.git, {git_dir, repo}
			next()
		.catch next
	
	app.param "git_ref", (req, res, next, git_ref) ->
		{repo} = req.git
		unless repo instanceof git.Repository
			return next new Error "No repository to lookup reference in"
		Promise.resolve repo.getReference git_ref
		.tap cleanup
		.then (ref) ->
			req.git = freeze req.git, {ref}
			next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	app.param "git_blob", (req, res, next, git_blob) ->
		{repo} = req.git
		unless repo instanceof git.Repository
			return next new Error "No repository to lookup blob in"
		Promise.resolve repo.find git_blob
		.tap cleanup
		.then (obj) ->
			unless typeof obj is git.Object.TYPE.BLOB
				throw new BadRequestError "Wrong  object type"
			Promise.resolve repo.getBlob obj.id()
		.tap cleanup
		.then (blob) ->
			req.git = freeze req.git, {blob}
			next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	if options.git_http_backend
		expressGit.gitHttpBackend app, assign {}, options.git_http_backend
	if options.serve_static
		app.get "/:git_repo(.*).git/:git_ref(.*)?/:git_service(blob)/:path(.*)", expressGit.serveBlob options

	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in NODEGIT_OBJECTS when typeof obj?.free is "function"
			obj.free()
		next()
	app
