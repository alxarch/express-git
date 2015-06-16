{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{NotFoundError, BadRequestError, NotModified} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options

	app.get "/:git_repo(.*).git/:git_service(raw)/:oid([a-zA-Z0-9]{40})", (req, res, next) ->
		{cleanup, repo} = req.git
		{oid} = req.params
		if oid is req.headers['if-none-match']
			return next new NotModified
		repo.then (repo) -> repo.getBlob oid
		.catch -> throw new NotFoundError
		.then cleanup
		.then (blob) ->
			res.set
				"Etag": "#{blob.id()}"
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
				"Content-Type": mime.lookup(path) or "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.write blob.content()
			res.end()
		.then -> next()
		.catch next

	app.get "/:git_repo(.*).git/:refname(.*)?/:git_service(raw)/:path(.*)", (req, res, next) ->
		{cleanup, repo} = req.git
		{path, refname} = req.params
		etag = req.headers['if-none-match']
		repo.then (repo) ->
			if refname
				repo.getReference refname
			else
				repo.head()
		.then cleanup
		.then (ref) -> repo.getCommit ref.target()
		.then cleanup
		.then (commit) -> commit.getEntry path
		.then cleanup
		.then (entry) ->
			unless entry.isBlob()
				throw new BadRequestError "Path is not a blob"
			if "#{entry.oid()}" is etag
				throw new NotModified
			entry.getBlob()
		.then cleanup
		.then (blob) ->
			res.set
				"Etag": "#{blob.id()}"
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
				"Content-Type": mime.lookup(path) or "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.write blob.content()
			res.end()
		.then -> next()
		.catch next
