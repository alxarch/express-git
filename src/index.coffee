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

	GIT_AUTH =
		if typeof options.authorize is "function"
		then options.authorize
		else (name, req, next) -> next()

	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_INIT_OPTIONS = freeze options.init_options

	app = express()
	app.project_root = GIT_PROJECT_ROOT
	app.git = git

	{NonHttpError, NotFoundError, BadRequestError, UnauthorizedError} = app.errors = require "./errors"

	app.disable "etag"

	app.authorize = (name) ->
		(req, res, next) ->
			GIT_AUTH name, req, (err) ->
				err?.status ?= 401
				next err

	app.cacheHeaders = (object) ->
		"Etag": "#{object.id()}"
		"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"

	app.use (req, res, next) ->
		# Initialization middleware
		NODEGIT_OBJECTS = []
		disposable = (value) ->
			NODEGIT_OBJECTS.push Promise.resolve value
			value

		repositories = new RepoManager GIT_PROJECT_ROOT,
			pattern: options.pattern
			auto_init: options.auto_init
			disposable: disposable
			init_options: GIT_INIT_OPTIONS

		# Hack to emit repositories events from app
		repositories.emit = app.emit.bind app

		req.git = freeze req.git, {repositories, disposable, NODEGIT_OBJECTS}
		next()

	app.param "git_repo", (req, res, next, path) ->
		try
			[name, params, git_dir] = req.git.repositories.parse path
		catch err
			err.status ?= 400
			return next err
		req.git_repo = {name, params, git_dir}
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

	app.use (req, res, next) ->
		Promise.settle req.git.NODEGIT_OBJECTS
		.map (inspection) ->
			if inspection.isFulfilled()
				try
					inspection.value()?.free()
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
