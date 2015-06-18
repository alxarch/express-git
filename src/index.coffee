{httpify, a2o, spawn, assign, freeze} = require "./helpers"
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

	app.hook = (name, args...) ->
		(req, res, next) ->
			GIT_HOOKS[name].apply {req, res}, args
			.then -> next()
			.catch next

	app.authorize = (name) ->
		(req, res, next) ->
			GIT_AUTH.call {req, res}, name
			.then -> next()
			.catch next

	app.cacheHeaders = (object) ->
		"Etag": "#{object.id()}"
		"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"

	app.use (req, res, next) ->
		authorize = (name) -> GIT_AUTH.call {req, res}, name
		hook = (name, args...) -> GIT_HOOKS[name].apply {req, res}, args
		NODEGIT_OBJECTS = []
		using = NODEGIT_OBJECTS.push.bind NODEGIT_OBJECTS
		open = (name, init=options.auto_init) ->
			m = "#{name.replace /\.git$/, ''}".match options.pattern
			decorate = (repo) -> assign repo, {name, params}
			unless m?
				return decorate Promise.reject new NotFoundError "Repository not found"
			
			params = m[1..]
			git_dir = _path.join GIT_PROJECT_ROOT, name

			decorate git.Repository.open git_dir,
				bare: yes
				ceilings: [GIT_PROJECT_ROOT]
			.then decorate
			.catch (err) ->
				throw err unless init and not test "-e", git_dir

				hook "pre-init", name
				.then (init_options) ->
					git.Repository.init git_dir, init_options or GIT_INIT_OPTIONS or {}
				.then decorate
				.then (repo) ->
					hook "post-init", repo
					.then -> repo
					.catch -> repo
			.then using
			.catch httpify 404

		refopen = (reponame, refname, callback) ->
			repo = open reponame, no
			ref = repo.then (repo) -> if refname then repo.getReference refname else repo.head()
			Promise.join repo, ref.then(using), callback
		
		req.git = freeze req.git, {using, hook, authorize, open, refopen, NODEGIT_OBJECTS}
		next()

	if options.git_http_backend
		expressGit.services.git_http_backend app, options
	if options.browse
		expressGit.services.browse app, options
		expressGit.services.object app, options
	if options.serve_static
		expressGit.services.raw app, options
	
	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in req.git.NODEGIT_OBJECTS when typeof obj?.free is "function"
			try
				obj.free()
		next()

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
