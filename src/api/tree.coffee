module.exports = (app, options) ->
	{BadRequestError, NotModified} = app.errors
	app.get "/:reponame(.*).git/:refname(.*)?/api/tree/:path(.*)?",
		app.authorize "api/blob",
		(req, res, next) ->
			{reponame, path, refname} = req.params
			{refopen, using} = req.git
			etag = req.headers["if-none-match"]
			refopen reponame, refname, (repo, ref) -> repo.getCommit ref.target()
			.then using
			.then (commit) ->
				if path
					commit.entryByPath path
					.then (entry) ->
						unless entry.isTree()
							throw new BadRequestError
						if entry.sha() is etag
							throw new NotModified		
						entry.getTree()
				else
					commit.getTree()
			.then using
			.then (tree) ->
				res.set app.cacheHeaders tree
				res.json
					type: "tree"
					name: _path.basename path
					path: path
					id: "#{tree.id()}"
				next()
			.catch next