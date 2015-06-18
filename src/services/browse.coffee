{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"
Promise = require "bluebird"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60

module.exports = (app, options) ->
	{BadRequestError, NotModified} = app.errors

	options = assign {}, SERVE_BLOB_DEFAULTS, options
	app.get "/:reponame(.*).git/:refname(.*)?/browse/:type(blob|tree|commit)/:path(.*)?",  (req, res, next) ->
		{using, open} = req.git
		{reponame, path, type, refname} = req.params
		etag = req.headers["if-none-match"]
		auth "browse"
		.then -> open reponame
		.then (repo) -> 
			if refname
				repo.getReference refname
			else
				repo.head()
		.then using
		.then (ref) ->
			if type is "commit" and "#{ref.target()}" is etag
				throw new NotModified()
			using repo.getCommit ref.target()
		.then (commit) ->
			if type is "commit"
				commit
			else if not path and type is "tree"
				if "#{commit.treeId()}" is etag
					throw new NotModified()
				using commit.getTree()
			else if path
				using commit.getEntry path
				.then (entry) ->
					if type is "tree"
						unless entry.isTree()
							throw new BadRequestError
						if etag is "#{entry.oid()}"
							throw new NotModified
						uning entry.getTree()
					else if type is "blob"
						unless entry.isBlob()
							throw new BadRequestError
						if etag is "#{entry.oid()}"
							throw new NotModified
						using entry.getBlob()
					else
						throw new BadRequestError
			else
				throw new BadRequestError
		.then (obj) ->
			res.set
				"Etag": "#{obj.id()}"
				"Cache-Control": "private, max-age=#{options.max_age}, no-transform, must-revalidate"
			res.json obj
			next()
		.catch next
