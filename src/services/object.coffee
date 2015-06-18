{assign} = require "../helpers"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{BadRequestError, NotModified, NotFoundError, NonHttpError} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options

	app.get "/:reponame(.*).git/object/:oid([a-zA-Z0-9]{40})", (req, res, next) ->
		{using, open, auth} = req.git
		{oid, reponame} = req.params
			return next new NotModified
		auth "object"
		.then ->
			if oid is req.headers["if-none-match"]
				throw new NotModified
			open reponame
		.then (repo) ->
			unless repo?
				throw new NotFoundError "Repository #{reponame} not found"
			using git.Object.lookup repo, oid, git.Object.TYPE.ANY
		.catch (err) ->
			throw new NotFoundError "#{err.message or err}"
		.then (obj) ->
			switch obj.type()
				when git.Object.TYPE.COMMIT
					repo.getCommit obj.id()
				when git.Object.TYPE.BLOB
					repo.getBlob obj.id()
				when git.Object.TYPE.TREE
					repo.getTree obj.id()
				else
					throw new BadRequestError
		.then using
		.then (obj) ->
			res.set
				"Etag": oid
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
			res.json obj
		.then -> next()
		.catch next
