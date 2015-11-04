{httpify, a2o, spawn, assign, freeze} = require "./helpers"
Promise = require "bluebird"

{mkdir, test} = require "shelljs"
# Use a modified express that uses latest path-to-regexp and events-as-promised
express = require "./express"
_path = require "path"

module.exports = expressGit = {}
expressGit.git = git = require "./ezgit"
expressGit.services = require "./services"
RepoManager = require "./repo-manager"

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
		GIT_AUTH = -> Promise.resolve()

	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_INIT_OPTIONS = freeze options.init_options

	app = express()
	app.repositories = new RepoManager GIT_PROJECT_ROOT,
		pattern: options.pattern
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

	app.getRepository = (path, init) ->
		app.repositories.open path
		.then (repo) -> [repo, no]
		.catch (err) ->
			throw err unless init
			init_options = assign {}, GIT_INIT_OPTIONS
			app.repositories.parse path
			.then ([name, params, git_dir]) ->
				app.emit "pre-init", name, params, init_options
				.then -> app.repositories.init path, init_options
				.then (repo) ->
					app.emit "post-init", repo
					.then -> [repo, yes]
					.catch -> [repo, yes]

	app.use (req, res, next) ->
		# Initialization middleware 

		NODEGIT_OBJECTS = []
		using = (objects) ->
			for obj in [].concat objects
				NODEGIT_OBJECTS.push obj
			objects

		open = (path, init) ->
			app.getRepository path, init ?= options.auto_init
			.then ([repo]) -> repo
			.then using
			.catch httpify 404

		refopen = (path, refname) ->
			app.repositories.refopen path, refname
			.then using
			.catch httpify 404

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

if require.main is module
	os = require "os"
	PORT = process.env.PORT
	ROOT = process.argv[2] or process.env.GIT_PROJECT_ROOT
	ROOT ?= _path.join os.tmpdir(), "express-git-repos"
	mkdir ROOT
	PORT ?= 20000 + (new Date().getTime() % 10000) | 0
	app = expressGit.serve ROOT, {}
	app.listen PORT, ->
		console.log "Listening on #{PORT}"
		console.log "Serving repos from #{_path.resolve ROOT}"
