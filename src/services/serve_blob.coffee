{assign} = require "../helpers"
mime = require "mime-types"

SERVE_BLOB_DEFAULTS = max_age: 365 * 24 * 60 * 60
expressGit.serveBlob = (options) ->
	options = assign {}, SERVE_BLOB_DEFAULTS, options
	(req, res, next) ->
		{blob} = req.git
		id = "#{blob.id()}"

		if id is req.headers['if-none-match']
			res.status 304
			res.end()
		else
			{max_age} = options
			path = req.params.git_blob.replace /.*:/, ''
			res.set "Etag", id
			res.set "Cache-Control", "private, max-age=#{max_age}, no-transform, must-revalidate"
			res.set "Content-Type", mime.lookup(path) or "application/octet-stream"
			res.set "Content-Length", blob.rawsize()
			res.write blob.content()
			res.end()
