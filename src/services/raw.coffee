mime = require "mime-types"
{httpify, assign} = require "../helpers"

module.exports = (app, options) ->
	{NotModified, NotFoundError, BadRequestError} = app.errors

	app.get "/:git_repo(.*).git/raw/:oid([a-zA-Z0-9]{40})", app.authorize("raw"), (req, res, next) ->
		{git_repo, oid} = req.params
		if oid is req.headers['if-none-match']
			return next new NotModified
		{repositories} = req.git

		repositories.blob git_repo, oid
		.then ([blob]) ->
			unless blob?
				throw new NotFoundError "Blob not found"
			res.set assign app.cacheHeaders blob,
				"Content-Type": "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.end blob.content()
			next()
		.catch next

	app.get "/:git_repo(.*).git/:refname(.*)?/raw/:path(.*)", app.authorize("raw"), (req, res, next) ->
		{git_repo, refname, path} = req.params
		unless path
			return next new BadRequestError "Invalid path"
		etag = req.headers['if-none-match']
		{repositories, disposable} = req.git
		repositories.entry git_repo, refname, path
		.then ([entry]) ->
			unless entry?
				throw new NotFoundError "Entry not found"
			unless entry.isBlob()
				throw new BadRequestError "Entry is not a blob"
			if etag is "#{entry.sha()}"
				throw new NotModified
			entry.getBlob()
		.then disposable
		.catch httpify 404
		.then (blob) ->
			res.set assign app.cacheHeaders(blob),
				"Content-Type": mime.lookup(path) or "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.end blob.content()
			next()
		.catch next
