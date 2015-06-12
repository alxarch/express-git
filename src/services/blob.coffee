{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS =
	max_age: 365 * 24 * 60 * 60
SERVE_BLOB_ROUTE = "/:git_repo(.*).git/:git_ref(.*)?/:git_service(blob)/:path(.*)"
module.exports = (app, options) ->
	{NotFoundError, NonHttpError} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options
	app.get SERVE_BLOB_ROUTE, (req, res, next) ->
		{cleanup, repo, ref} = req.git
		{path} = req.params
		Promise.resolve if ref then repo.getCommit(ref.target()) else repo.getHeadCommit()
		.then cleanup
		.then (commit) -> Promise.resolve commit.getEntry path
		.then cleanup
		.then (entry) ->
			unless entry.isBlob()
				throw new NotFoundError "Blob not found"
			Promise.resolve entry.getBlob()
		.then cleanup
		.then (blob) ->
			id = "#{blob.id()}"

			if id is req.headers['if-none-match']
				res.status 304
				res.end()
			else
				res.set
					"Etag": id
					"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
					"Content-Type": mime.lookup(path) or "application/octet-stream"
					"Content-Length": blob.rawsize()
				res.write blob.content()
				res.end()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next
