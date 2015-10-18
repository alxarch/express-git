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
	serve_static: yes
	accept_commits: yes
	refs: yes
	auto_init: yes
	browse: yes
	init_options: {}
	max_size: 2 * 1024
	max_age: 365 * 24 * 60 * 60
	pattern: /.*/
	authorize: null

expressGit.serve = (root, options) ->
	options = assign {}, EXPRESS_GIT_DEFAULTS, options
	unless options.pattern instanceof RegExp
		options.pattern = new Regexp "#{options.pattern or '.*'}"
	if typeof options.authorize is "function"
		GIT_AUTH = Promise.promisify options.authorize
	else
		GIT_AUTH = Promise.resolve()

	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_INIT_OPTIONS = freeze options.init_options

	app = express()
	app.project_root = GIT_PROJECT_ROOT
	app.git = git

	{NonHttpError, NotFoundError, BadRequestError, UnauthorizedError} = app.errors = require "./errors"

	app.disable "etag"

	app.authorize = (name) ->
		(req, res, next) ->
			GIT_AUTH.call {req, res}, name
			.catch httpify 401
			.then -> next()
			.catch next

	app.cacheHeaders = (object) ->
		"Etag": "#{object.id()}"
		"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"

	app.use (req, res, next) ->
		NODEGIT_OBJECTS = []
		using = (obj) ->
			NODEGIT_OBJECTS.push obj
			obj
		open = (name, init=options.auto_init) ->
			[name, params...] = ("#{name.replace /\.git$/, ''}".match options.pattern) or []
			unless name?
				return Promise.reject new NotFoundError "Repository not found"

			git_dir = _path.join GIT_PROJECT_ROOT, name

			git.Repository.open git_dir,
				bare: yes
				ceilings: [GIT_PROJECT_ROOT]
			.then using
			.catch httpify 404
			.catch (err) ->
				if init and not test "-e", git_dir
					init_options = assign {}, GIT_INIT_OPTIONS
					app.emit "pre-init", name, params, init_options
					.then -> git.Repository.init git_dir, init_options
					.then using
					.then (repo) ->
						app.emit "post-init", name, params, repo
						.then -> repo
				else
					throw err

		refopen = (reponame, refname, callback) ->
			repo = open reponame, no
			ref = repo.then (re) ->
				if refname
					re.getReference refname
				else
					re.head()
			Promise.join repo, ref.then(using), callback

		req.git = freeze req.git, {using, open, refopen, NODEGIT_OBJECTS}
		next()

	if options.browse
		expressGit.services.browse app, options
		expressGit.services.object app, options
	if options.accept_commits
		expressGit.services.commit app, options
	if options.serve_static
		expressGit.services.raw app, options
	if options.git_http_backend
		expressGit.services.git_http_backend app, options
	if options.refs
		expressGit.services.refs app, options

	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in req.git.NODEGIT_OBJECTS when typeof obj?.free is "function"
			try
				obj.free()
		next()

	app
