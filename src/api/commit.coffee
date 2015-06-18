module.exports = (app, options) ->
	{open, authorize, using} = app
	{BadRequestError, NotModified} = app.errors
	app.get "/:reponame(.*).git/api/commit/:refname(.*)?",
		authorize "api/commit"
		(req, res, next) ->
			{reponame, refname} = req.params
			{refopen, using} = req.git
			etag = req.headers["if-none-match"]
			refopen reponame, refname, (repo, ref) ->
				oid = ref.target()
				if "#{oid}" is etag
					throw new NotModified
				repo.getCommit oid
			.then using
			.then (commit) ->
				res.set app.cacheHeaders commit
				res.json
					type: "commit"
					id: "#{commit.id()}"
					tree: "#{commit.treeId()}"
					message: commit.message()
				next()
			.catch next