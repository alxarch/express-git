{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{NotFoundError, NonHttpError} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options
	app.get "/:git_repo(.*).git/:git_service(object)/:oid([a-zA-Z0-9]{40})", (req, res, next) ->
		{cleanup, repo} = req.git
		{oid} = req.params
		git.Object.lookup repo, oid, git.Object.TYPE.ANY
		.then cleanup
		.then (obj) ->
			id = "#{obj.id()}"

			if id is req.headers['if-none-match']
				res.status 304
				res.end()
				return
			o = switch obj.type()
				when git.Object.TYPE.COMMIT
					repo.getCommit obj.id()
				when git.Object.TYPE.BLOB
					repo.getBlob obj.id()
				when git.Object.TYPE.TREE
					repo.getTree obj.id()
				else
					throw new NotFoundError "Object #{oid} not found"
			o.then(cleanup).then (obj) ->
				res.set
					"Etag": id
					"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
				res.json obj
		.then -> next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	app.get "/:git_repo(.*).git/:git_ref(.*)?/:git_service(tree)/:path(.*)", (req, res, next) ->
		{cleanup, repo, ref} = req.git
		{path} = req.params
		Promise.resolve if ref then repo.getCommit(ref.target()) else repo.getHeadCommit()
		.then cleanup
		.then (commit) ->
			if path
				commit.getEntry(path)
				.then cleanup
				.then (entry) ->
					unless entry.isTree()
						throw new NotFoundError "Tree not found"
					entry.oid()
			else
				commit.treeId()
		.then (oid) ->
			id = "#{oid}"
			if id is req.headers['if-none-match']
				res.status 304
				res.end()
				return
			git.Tree.lookup repo, oid
			.then cleanup
			.then (tree) ->
				tree.path = -> path
				res.set
					"Etag": id
					"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
				res.json tree
		.then -> next()
		.catch NonHttpError, (err) -> throw new NotFoundError err.message
		.catch next

	app.get "/:git_repo(.*).git/:git_ref(.*)?/:git_service(blob)/:path(.*)", (req, res, next) ->
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
