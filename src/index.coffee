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
	accept_commits: yes
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
	{NonHttpError, NotFoundError, BadRequestError, UnauthorizedError} = errors = require "./errors"
	unless options.pattern instanceof RegExp
		options.pattern = new Regexp "#{options.pattern or '.*'}"
	if typeof options.auth is "function"
		GIT_AUTH = Promise.promisify options.auth
	else
		GIT_AUTH = -> Promise.resolve()
	
	app.authorize = (service) ->
		(req, res, next) ->
			GIT_AUTH.call {req, res}, service
			.then -> next()
			.catch next

	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_INIT_OPTIONS = freeze options.init_options
	GIT_HOOKS = do ->
		hooks = {}
		for own hook, callback of options.hooks when typeof callback is "function"
			hooks[hook] = Promise.promisify hook
		assign {}, EXPRESS_GIT_DEFAULT_HOOKS, hooks

	app = express()
	app.errors = errors


	NODEGIT_OBJECTS = []
	using = app.using = (obj) ->
		if obj instanceof git.Promise or obj instanceof Promise
			return obj.then using
		else if obj?
			NODEGIT_OBJECTS.push obj
		obj
	cleanup = (obj) ->
		if obj?
			NODEGIT_OBJECTS.push obj
		obj

	app.disable "etag"
	app.hook = -> throw new Error "Cannot trigger a hook out of a request"
	app.auth = -> throw new Error "Cannot authorize an action out of a request"
	app.open =  (reponame, auto_init=options.auto_init) ->
		reponame = reponame.replace /\.git$/, ''
		m = "#{reponame}".match options.pattern
		decorate = (repo) ->
			return repo unless repo?
			repo.name = reponame
			repo.params = params
			repo.git_dir = git_dir
			repo
		unless m?
			return Promise.reject new BadRequestError "Repository name '#{reponame}' is invalid"
		git_dir = _path.join GIT_PROJECT_ROOT, reponame
		# TODO: use path-to-regexp for named params
		params = freeze a2o m[1..]

		decorate git.Repository.open git_dir,
			bare: yes
			# Set the topmost dir to GIT_PROJECT_ROOT to avoid
			# searching in it's parents for .git dirs
			ceilings: [GIT_PROJECT_ROOT]
		.catch (err) ->
			if not auto_init or test "-e", git_dir
				throw err

			hook "pre-init", reponame
			.then (init_options) ->
				git.Repository.init git_dir, init_options or GIT_INIT_OPTIONS or {}
			.then (repo) ->
				hook "post-init", repo
				.then -> repo
		.then (repo) -> using decorate repo
		.catch httpify 404

	app.refopen = (reponame, refname, callback) ->
		repo = open reponame, no
		ref = repo.then (repo) ->
			if refname
				repo.getReference refname
			else
				do repo.head
		.then using
		.catch httpify 404
		Promise.join repo, ref, callback

	app.use (req, res, next) ->
		res.cacheHeaders = (object) ->
			res.set
				"Etag": "#{object.id()}"
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"

		res.blob = (blob, path) ->
			res.cacheHeaders blob
			res.set
				"Content-Type": mime.lookup(path) or "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.end blob.content()

		app.hook = (name, args...) -> GIT_HOOKS[name]?.apply {req, res}, args


		authorize = (service) -> GIT_AUTH.call {req, res}, service
		req.git = freeze req.git, {refopen, authorize, hook, open, using}
		next()

	if options.git_http_backend
		expressGit.services.git_http_backend app, options
	if options.browse
		expressGit.services.browse app, options
		expressGit.services.object app, options
	if options.serve_static
		expressGit.services.raw app, options
	if options.accept_commits
		expressGit.services.commit app, options

	
	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in NODEGIT_OBJECTS when typeof obj?.free is "function"
			try
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
