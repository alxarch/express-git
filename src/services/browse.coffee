{httpify, assign} = require "../helpers"
mime = require "mime-types"
_path = require "path"
module.exports = (app, options) ->
	{BadRequestError, NotModified} = app.errors
	app.get "/:reponame(.*).git/:refname(.*)?/commit",
		app.authorize "browse"
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
				res.json assign {type: "commit"}, commit.toJSON()
				next()
			.catch next

	app.get "/:reponame(.*).git/:refname(.*)?/blob/:path(.*)",
		app.authorize "browse"
		(req, res, next) ->
			{using, refopen} = req.git
			{reponame, path, refname} = req.params
			unless path
				return next new BadRequestError
			etag = req.headers["if-none-match"]
			refopen reponame, refname, (repo, ref) ->
				repo.getCommit ref.target()
			.then using
			.then (commit) -> commit.getEntry path
			.then using
			.then (entry) ->
				if entry.isTree()
					throw new BadRequestError
				if entry.sha() is etag
					throw new NotModified
				entry.getBlob()
			.then using
			.then (blob) ->
				binary = if blob.isBinary() then yes else no
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
			.catch httpify 404
			.catch next

	app.get "/:reponame(.*).git/:refname(.*)?/tree/:path(.*)?",
		app.authorize "browse"
		(req, res, next) ->
			{reponame, path, refname} = req.params
			{refopen, using} = req.git
			etag = req.headers["if-none-match"]
			refopen reponame, refname, (repo, ref) ->
				repo.getCommit ref.target()
			.then using
			.then (commit) ->
				if path
					commit.getEntry path
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
					id: "#{tree.id()}"
					name: _path.basename path
					path: path
					entries: (entry.toJSON() for entry in tree.entries())
				next()
			.catch next
