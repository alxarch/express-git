{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"
{NotFoundError, NonHttpError} = require "../errors"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60
module.exports = (options) ->
	options = assign {}, SERVE_BLOB_DEFAULTS, options
	(req, res, next) ->
		{cleanup, repo, ref} = req.git
		{path} = req.params
		Promise.resolve if ref then repo.getCommit(ref.target()) else repo.getHeadCommit()
		.tap cleanup
		.then (commit) -> Promise.resolve commit.getEntry path
		.tap cleanup
		.then (entry) ->
			unless entry.isBlob()
				throw new NotFoundError "Blob not found"
			Promise.resolve entry.getBlob()
		.tap cleanup
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
