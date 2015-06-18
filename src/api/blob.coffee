module.exports = (app, options) ->
	{BadRequestError, NotModified} = app.errors
	app.get "/:reponame(.*).git/:refname(.*)?/api/blob/:path(.*)",
		app.authorize "api/blob",
		(req, res, next) ->
			{using, refopen} = req.git
			{reponame, path, refname} = req.params
			unless path
				return next new BadRequestError
			etag = req.headers["if-none-match"]
			refopen reponame, refname, (repo, ref) ->
				repo.getCommit ref.target()
			.then using
			.then (commit) -> commit.entryByPath path
			.then using
			.then (entry) ->
				if entry.isTree()
					throw new BadRequestError
				if entry.sha() is etag
					throw new NotModified
				entry.getBlob()
			.then using
			.then (blob) ->
				binary = blob.isBinary()
				size = blob.rawsize()
				content = blob.content()
				truncate = size > options.max_size
				if truncate
					content = content.slice 0, options.max_size
				encoding = if binary then "base64" else "utf8"
				res.set app.cacheHeaders blob
				res.json
					type: "blob"
					id: "#{blob.id()}"
					binary: binary
					mime: mime.lookup path
					path: path
					filename: _path.basename path
					contents: blob.toString encoding
					truncated: truncate
					encoding: encoding
					size: size
				next()
			.catch next