{assign} = require "../helpers"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{BadRequestError, NotModified, NotFoundError, NonHttpError} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options

	app.get "/:git_repo(.*).git/:git_service(object)/:oid([a-zA-Z0-9]{40})", (req, res, next) ->
		{cleanup, repo} = req.git
		{oid} = req.params
		if oid is req.headers["if-none-match"]
			return next new NotModified
		repo.then (repo) -> git.Object.lookup repo, oid, git.Object.TYPE.ANY
		.then cleanup
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
		.then cleanup
		.then (obj) ->
			res.set
				"Etag": oid
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
			res.json obj
		.then -> next()
		.catch next

