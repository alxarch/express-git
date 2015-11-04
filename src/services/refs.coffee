git = require "../ezgit"

module.exports = (app, options) ->
	{MethodNotAllowedError, ConflictError, BadRequestError} = app.errors

	app.delete "/:reponame(.*).git/:refname(refs/.*)",
		app.authorize "refs"
		(req, res, next) ->
			{using, refopen} = req.git
			{reponame, refname, path} = req.params
			unless current and message
				return next new BadRequestError

			refopen reponame, refname
			.then([repo, ref]) ->
				unless ref?
					res.set "Allow", "PUT"
					throw new MethodNotAllowedError

				git.Reference.remove repo, refname
			.then (code) ->
				if code is 0
					res.json message: "OK"
					next()
				else
					throw new Error "Error code #{code}"
			.catch next

	app.put "/:reponame(.*).git/:refname(refs/.*)",
		app.authorize "refs"
		require("body-parser").json()
		(req, res, next) ->
			{using, refopen} = req.git
			{reponame, refname, path} = req.params
			{target, current, message, signature, symbolic} = req.body
			unless target and message and current
				return next new BadRequestError

			refopen reponame, refname
			.then ([repo, ref]) ->
				if signature?
					try
						signature = git.Signature.create signature
					catch err
						signature = null
				signature ?= git.Signature.default repo
				if ref?
					if symbolic
						unless ref.isSymbolic()
							throw new BadRequestError
						unless "#{ref.symbolicTarget()}" is target
							throw new BadRequestError
						ref.symbolicSetTarget target, signature, message
					else
						unless "#{ref.target()}" is current
							throw new ConflictError
						target = git.Oid.fromString target
						ref.setTarget target, signature, message
				else
					if symbolic
						git.Reference.symbolicCreate repo, refname, target, 0, signature, message
					else
						target = git.Oid.fromString target
						git.Reference.create repo, refname, target, 0, signature, message
			.then using
			.then (ref) ->
				res.json ref
				next()
			.catch next
