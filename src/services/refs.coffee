git = require "../ezgit"

module.exports = (app, options) ->
	{MethodNotAllowedError, ConflictError, BadRequestError} = app.errors

	app.delete "/:reponame(.*).git/:refname(refs/.*)",
		app.authorize "refs"
		(req, res, next) ->
			{reponame, refname, path} = req.params
			unless current and message
				return next new BadRequestError
			{repositories, disposable} = req.git
			repositories.ref reponame, refname
			.then([ref, repo]) ->
				unless ref?
					res.set "Allow", "PUT"
					throw new MethodNotAllowedError
				git.Reference.remove repo, refname
			.then (code) ->
				unless code is 0
					throw new Error "Error code #{code}"
				res.json message: "OK"
				next()
			.catch next

	app.put "/:reponame(.*).git/:refname(refs/.*)",
		app.authorize "refs"
		require("body-parser").json()
		(req, res, next) ->
			{target, current, message, signature, symbolic} = req.body
			unless target and message and current
				return next new BadRequestError

			{reponame, refname, path} = req.params
			{repositories, disposable} = req.git
			repositories.openOrInit reponame
			.then -> repositories.ref reponame, refname
			.then ([ref, repo]) ->
				Promise.try -> if signature? then git.Signature.create signature else null
				.catch -> null
				.then (signature) -> signature ?= git.Signature.default repo
				.then disposable
				.then (signature) -> [repo, ref, signature]
			.then ([repo, ref, signature]) ->
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
			.then disposable
			.then (ref) -> res.json ref
			.then -> next()
			.catch next
