{httpify} = require "../helpers"
module.exports = (app, options) ->
	{git} = app
	{BLOB, TREE, COMMIT, TAG} = git.Object.TYPE
	{BadRequestError, NotModified} = app.errors
	app.get "/:reponame(.*).git/object/:oid([a-zA-Z0-9]{40})",
		app.authorize "browse"
		(req, res, next) ->
			{reponame, oid} = req.params
			{repositories, disposable} = req.git
			if oid is req.headers["if-none-match"]
				return next new NotModified

			repositories.open reponame
			.then (repo) -> git.Object.lookup repo, oid
			.then disposable
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
			.then disposable
			.catch httpify 404
			.then (object) ->
				res.set app.cacheHeaders object
				res.json object
				next()
			.catch next
