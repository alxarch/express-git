{assign} = require "../helpers"
mime = require "mime-types"
git = require "../ezgit"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60
expressGit.serveBlob = (options) ->
	options = assign {}, SERVE_BLOB_DEFAULTS, options
	(req, res, next) ->
		{ref, repo} = req.git
		{path} = req.params
		git.Commit.lookup  repo, ref.target()
		.then (commit) ->
			req._nodegit_objects.push commit
			commit.getEntry path
		.then (entry) ->
			req._nodegit_objects.push entry
			unless entry.isBlob()
				throw new NotFoundError "Blob not found"
			entry.getBlob()
		.then (blob) ->
			req._nodegit_objects.push blob

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
		.catch next
