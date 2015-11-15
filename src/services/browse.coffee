{httpify, assign} = require "../helpers"
mime = require "mime-types"
_path = require "path"
module.exports = (app, options) ->
	{BadRequestError, NotModified, NotFoundError} = app.errors
	app.get "/:git_repo(.*).git/:refname(.*)?/commit",
		app.authorize "browse"
		(req, res, next) ->
			{git_repo, refname} = req.params
			{repositories, disposable} = req.git
			etag = req.headers["if-none-match"]
			repositories.ref git_repo, refname
			.then ([ref, repo]) ->
				unless repo? and ref?
					throw new NotFoundError
				if "#{ref.target()}" is etag
					throw new NotModified
				repo.getCommit ref.target()
			.then disposable
			.then (commit) ->
				res.set app.cacheHeaders commit
				res.json assign {type: "commit"}, commit.toJSON()
			.then -> next()
			.catch next

	app.get "/:git_repo(.*).git/:refname(.*)?/blob/:path(.*)",
		app.authorize("browse")
		(req, res, next) ->
			{git_repo, path, refname} = req.params
			unless path
				return next new BadRequestError
			{repositories, disposable} = req.git
			etag = req.headers["if-none-match"]
			repositories.entry git_repo, refname, path
			.then ([entry]) ->
				unless entry?
					throw new NotFoundError "Entry not found"
				if entry.isTree()
					throw new BadRequestError
				if entry.sha() is etag
					throw new NotModified
				entry.getBlob()
			.then disposable
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
			.then -> next()
			.catch httpify 404
			.catch next

	app.get "/:git_repo(.*).git/:refname(.*)?/tree/:path(.*)?",
		app.authorize "browse"
		(req, res, next) ->
			{git_repo, path, refname} = req.params
			{repositories, disposable} = req.git

			etag = req.headers["if-none-match"]
			repositories.commit git_repo, refname
			.then ([commit]) ->
				if path
					commit.getEntry path
					.then disposable
					.then (entry) ->
						unless entry.isTree()
							throw new BadRequestError
						if entry.sha() is etag
							throw new NotModified
						entry.getTree()
				else
					commit.getTree()
			.then disposable
			.then (tree) ->
				res.set app.cacheHeaders tree
				res.json
					type: "tree"
					id: "#{tree.id()}"
					name: _path.basename path
					path: path
					entries: (entry.toJSON() for entry in tree.entries())
			.then -> next()
			.catch next
