{a2o, spawn, assign, freeze} = require "./helpers"
{NotFoundError, BadRequestError, UnauthorizedError} = require "./errors"
Promise = require "bluebird"

{mkdir, test} = require "shelljs"
express = require "./express"
_path = require "path"

module.exports = expressGit = {}
expressGit.git = git = "./ezgit"
expressGit.gitHttpBackend = require "./services/git_http_backend"
expressGit.serveBlob  = require "./services/git_http_backend"

EXPRESS_GIT_DEFAULTS =
	git_http_backend: yes
	auto_init: yes
	pattern: /.*/
	auth: null
	services:
		"/:git_repo(.*)/:git_ref(.*)?/:git_service(blob)/:path(.*)":
			get: expressGit.serveBlob options

expressGit.serve = (root, options) ->
	options = _.assign {}, options, EXPRESS_GIT_DEFAULTS
	unless options.pattern instanceof RegExp
		options.pattern = new Regexp "#{options.pattern or '.*'}"
	unless typeof options.auth is "function"
		options.auth = (req, res, next) -> next()
	
	GIT_PROJECT_ROOT = _path.resolve "#{root}"
	GIT_TEMPLATE_PATH = _path.resolve __dirname, "..", "templates"
	GIT_INIT_OPTIONS = freeze options.auto_init, template: GIT_TEMPLATE_PATH
	
	app = express()
	
	NODEGIT_OBJECTS = []

	app.disable "etag"


	app.param "git_service", (req, res, next, service) ->
		if service is "info/refs" and req.method is "get"
			{service} = req.query
			unless service in ["upload-pack", "receive-pack"]
				return next new BadRequestError "Invalid service #{service}"

		cb = (err) ->
			if err
				next if err.status then err else new UnauthorizedError err.message
			else
				req.git = freeze req.git, {service}
				next()
		options.auth req, res, cb, service

	app.param "git_repo", (req, res, next, reponame) ->
		m = "#{reponame}".match options.pattern
		unless m?
			return next new NotFoundError "Repository not found"
		git_dir = _path.join GIT_PROJECT_ROOT, reponame
		git.Repository.open git_dir,
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
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{git_repo} not found"
			NODEGIT_OBJECTS.push repo
			# TODO: use path-to-regexp for named params
			repo.params = freeze a2o m[1..]
			repo.name = reponame
			req.git = freeze req.git, {git_dir, repo}
		.catch next
	
	app.param "git_ref", (req, res, next, git_ref) ->
		unless req.git.repo instanceof git.Repository
			throw new Error "No repository to lookup reference in"
		repo.getReference git_ref
		.then (ref) ->
			NODEGIT_OBJECTS.push ref
			req.git = freeze req.git, {ref}
			next()
		.catch (err) -> throw if err.status then err else new NotFoundError err.message
		.catch next

	app.param "git_blob", (req, res, next, git_blob) ->
		unless req.git.repo instanceof git.Repository
			throw new Error "No repository to lookup blob in"
		repo.find git_blob
		.then (obj) ->
			NODEGIT_OBJECTS.push obj
			unless typeof obj is git.Object.TYPE.BLOB
				throw new BadRequestError "Wrong  object type"
			git.Blob.lookup obj.id().cpy()
		.then (blob) ->
			NODEGIT_OBJECTS.push blob
			req.git = freeze req.git, {blob}
			next()
		.catch (err) -> throw if err.status then err else new NotFoundError err.message
		.catch next

	app.use (req, res, next) ->
		req._nodegit_objects = NODEGIT_OBJECTS
		next()

	if options.git_http_backend
		app.use expressGit.gitHttpBackend assign {}, options.git_http_backend
	
	app.registerService = (method="use", route, handler) ->
		unless typeof app[method] is "function"
			throw new TypeError "Invalid method #{method}"
		unless isMiddleware handler
			throw new TypeError "Invalid service handler for #{route}"

		app[method] route, handler
		app

	for route, service of options.services
		if isMiddleware service
			app.registerService route, service
		else if typeof service is "object"
			for own method, handler of service
				app.registerService method, route, service

	# Cleanup nodegit objects
	app.use (req, res, next) ->
		for obj in NODEGIT_OBJECTS when typeof obj?.free is "function"
			obj.free()
		next()
	app
