{httpify} = require "../helpers"
module.exports = (app, options) ->
	{git} = app
	{BLOB, TREE, COMMIT, TAG} = git.Object.TYPE
	{BadRequestError, NotModified} = app.errors
	app.get "/:repo(.*).git/object/:oid([a-zA-Z0-9]{40})",
		app.authorize "browse"
		(req, res, next) ->
			{repo, oid} = req.params
			{using, open} = req.git
			if oid is req.headers["if-none-match"]
				return next new NotModified

			open repo, no
			.then (repo) -> git.Object.lookup repo, oid
			.then using
			.then (object) ->
				switch object.type()
					when BLOB
						git.Blob.lookup repo, oid
					when TREE
						git.Tree.lookup repo, oid
					when COMMIT
						git.Commit.lookup repo, oid
					when TAG
						git.Tag.lookup repo, oid
					else
						throw new BadRequestError
			.then using
			.catch httpify 404
			.then (object) ->
				res.set app.cacheHeaders object
				res.json object
				next()
			.catch next
