module.exports = (app, options) ->
	{git} = app
	{NotModified, BadRequestError} = app.errors

	app.get "/:repo(.*).git/api/object/:oid([a-zA-Z0-9]{40})",
		app.authorize "api/object",
		(req, res, next) ->
			{repo, oid} = req.params
			if oid is req.headers["if-none-match"]
				return next new NotModified
			req.git.open repo, no
			.then (repo) -> git.Object.lookup repo, oid
			.then using
			.catch httpize 404
			.then (object) ->
				switch object.type() 
					when BLOB
						git.Blob.lookup repo, oid
					when TREE
						git.Tree.lookup repo, oid
					when COMMIT
						git.Commit.lookup repo, oid
					else
						throw new BadRequestError
			.then using
			.then (object) ->
				res.set app.cacheHeaders object
				res.json object
				next()
			.catch next