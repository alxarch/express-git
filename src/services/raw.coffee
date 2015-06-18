{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{NotFoundError, BadRequestError, NotModified} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options

	app.get "/:reponame(.*).git/raw/:oid([a-zA-Z0-9]{40})", app.authorize("raw"), (req, res, next) ->
		{using, auth, open} = req.git
		{oid, reponame} = req.params
		auth "raw"
		.then ->
			if oid is req.headers['if-none-match']
				throw new NotModified
			open reponame
		.then (repo) -> using repo.getBlob oid
		.catch -> throw new NotFoundError "Blob not found"
		.then (blob) ->
			res.set
				"Etag": "#{blob.id()}"
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
				"Content-Type": "application/octet-stream"
				"Content-Length": blob.rawsize()
			res.write blob.content()
			res.end()
		.then -> next()
		.catch next

	app.get "/:reponame(.*).git/:refname(.*)?/raw/:path(.*)", app.authorize("raw"), (req, res, next) ->
		{auth, open, using} = req.git
		{reponame, path, refname} = req.params
		auth "raw"
		.then -> open reponame
		.then (repo) ->
			if refname
				using repo.getReference refname
			else
				using repo.head()
		.then (ref) -> using repo.getCommit ref.target()
		.then (commit) -> using commit.getEntry path
		.then (entry) ->
			unless entry.isBlob()
				throw new BadRequestError "Path is not a blob"
			etag = req.headers['if-none-match']
			if "#{entry.oid()}" is etag
				throw new NotModified
			using entry.getBlob()
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
