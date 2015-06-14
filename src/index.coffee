{a2o, spawn, assign, freeze} = require "./helpers"
Promise = require "bluebird"

{mkdir, test} = require "shelljs"
express = require "./express"
_path = require "path"

module.exports = expressGit = {}
expressGit.git = git = require "./ezgit"
expressGit.services = require "./services"

EXPRESS_GIT_DEFAULTS =
	git_http_backend: yes
	hooks: {}
	serve_static: yes
	auto_init: yes
	browse: yes
	init_options: {}
	pattern: /.*/
	auth: null
EXPRESS_GIT_DEFAULT_HOOKS =
	'pre-init': Promise.resolve
	'post-init': Promise.resolve
	'pre-receive': Promise.resolve
	'post-receive': Promise.resolve
	'update': Promise.resolve

expressGit.serve = (root, options) ->
	options = assign {}, options, EXPRESS_GIT_DEFAULTS
	unless options.pattern instanceof RegExp
		options.pattern = new Regexp "#{options.pattern or '.*'}"
	if typeof options.auth is "function"
		GIT_AUTH = Promise.promisify options.auth
	else
		GIT_AUTH = -> Promise.resolve null

	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_INIT_OPTIONS = freeze options.init_options
	GIT_HOOKS = do ->
		hooks = {}
		for own hook, callback of options.hooks when typeof callback is "function"
			hooks[hook] = Promise.promisify hook
		assign {}, EXPRESS_GIT_DEFAULT_HOOKS, hooks

	app = express()

	{NonHttpError, NotFoundError, BadRequestError, UnauthorizedError} = app.errors = require "./errors"

	NODEGIT_OBJECTS = []
	cleanup = (obj) ->
		NODEGIT_OBJECTS.push obj
		obj

	app.disable "etag"

	app.use (req, res, next) ->
		hook = (name, args...) -> GIT_HOOKS[name]?.apply {req, res}, args
		auth = (args...) -> GIT_AUTH.apply {req, res}, args
		req.git = freeze req.git, {cleanup, hook, auth}
		next()

	app.param "git_service", (req, res, next, service) ->
		if service is "info/refs" and req.method is "GET"
			{service} = req.query
			if service in ["git-upload-pack", "git-receive-pack"]
				service = service.replace "git-", ""
			else
				return next new BadRequestError "Invalid service #{service}"

		req.git.auth service
		.then ->
			req.git = freeze req.git, {service}
			next()
		.catch NonHttpError, (err) -> throw new UnauthorizedError err.message
		.catch next

	app.param "git_repo", (req, res, next, reponame) ->
		reponame = reponame.replace /\.git$/, ''
		m = "#{reponame}".match options.pattern
		unless m?
			return next new NotFoundError "Repository not found"
		decorateRepo = (repo) ->
			# TODO: use path-to-regexp for named params
			repo.name = reponame
			repo.params = freeze a2o m[1..]
			repo
		git_dir = _path.join GIT_PROJECT_ROOT, reponame
		git.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.then decorateRepo
		.catch (err) ->
			if options.auto_init and not test "-e", git_dir
				req.git.hook "pre-init", reponame
				.then (init_options) -> git.Repository.init git_dir, init_options or GIT_INIT_OPTIONS or {}
				.then decorateRepo
				.then (repo) ->
					req.git.hook "post-init", repo
					.then -> repo
			else
				null
		.catch NonHttpError, -> null
		.then cleanup
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{reponame} not found"
			req.git = freeze req.git, {git_dir, repo}
			next()
		.catch next

	app.param "git_ref", (req, res, next, git_ref) ->
		{repo} = req.git
		unless repo instanceof git.Repository
			return next new Error "No repository to lookup reference in"
		repo.getReference git_ref
		.then cleanup
		.then (ref) ->
			req.git = freeze req.git, {ref}
			next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	app.param "git_blob", (req, res, next, git_blob) ->
		{repo} = req.git
		unless repo instanceof git.Repository
			return next new Error "No repository to lookup blob in"
		repo.find git_blob
		.then cleanup
		.then (obj) ->
			unless typeof obj is git.Object.TYPE.BLOB
				throw new BadRequestError "Wrong  object type"
			repo.getBlob obj.id()
		.then cleanup
		.then (blob) ->
			req.git = freeze req.git, {blob}
			next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	if options.git_http_backend
		expressGit.services.git_http_backend app, options
	if options.browse
		expressGit.services.browse app, options
		expressGit.services.object app, options
	if options.serve_static
		expressGit.services.raw app, options

	
	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in NODEGIT_OBJECTS when typeof obj?.free is "function"
			obj.free()
		next()
	app.use app.errors.httpErrorHandler
	app

unless module.parent
	port = process.env.EXPRESS_GIT_PORT or 9000
	root = process.env.EXPRESS_GIT_ROOT or "/tmp/repos"
	app = express()
	app.use require("morgan") "dev"
	app.use expressGit.serve root
	app.use (err, req, res, next) ->
		console.error err.stack
		next err
	app.listen port, ->
		console.log "Express git serving #{root} on port #{9000}"
