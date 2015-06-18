mime = require "mime"
{httpize} = require "../helpers"

module.exports = (app, options) ->
	{NotModified, NotFoundError, BadRequestError} = app.errors

	app.get "/:reponame(.*).git/api/raw/:oid([a-zA-Z0-9]{40})",
		authorize "api/raw"
		(req, res, next) ->
			{reponame, oid} = req.params
			if oid is req.headers['if-none-match']
				return next new NotModified
			{open, using} = req.git
			open reponame, no
			.then (repo) -> repo.getBlob oid
			.then using
			.catch httpize 404
			.then (blob) ->
				res.set app.cacheHeaders blob
				res.set
					"Content-Type": mime.lookup(path) or "application/octet-stream"
					"Content-Length": blob.rawsize()
				res.end blob.content()
				next()
			.catch next

	app.get "/:reponame(.*).git/:refname(.*)?/api/raw/:path(.*)",
		authorize "api/raw"
		(req, res, next) ->
			{reponame, oid} = req.params
			unless path
				return next new BadRequestError
			if oid is req.headers['if-none-match']
				return next new NotModified
			{refopen, using} = req.git
			refopen reponame, refname, (repo, ref) ->
				repo.getCommit ref.target()
			.then using
			.then (commit) -> commit.entryByPath path
			.then using
			.then (entry) ->
				unless entry.isBlob()
					throw new BadRequestError
				if etag is "#{entry.sha()}"
					throw new NotModified
				entry.getBlob()
			.then using
			.catch httpize 404
			.then (blob) ->
				res.set app.cacheHeaders blob
				res.set
					"Content-Type": mime.lookup(path) or "application/octet-stream"
					"Content-Length": blob.rawsize()
				res.end blob.content()
				next()
			.catch next