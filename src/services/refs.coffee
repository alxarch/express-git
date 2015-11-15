git = require "../ezgit"

module.exports = (app, options) ->
	{MethodNotAllowedError, ConflictError, BadRequestError} = app.errors

	app.delete "/:git_repo(.*).git/:refname(refs/.*)", app.authorize("refs"), (req, res, next) ->
		{git_repo, refname} = req.params
		unless current and message
			return next new BadRequestError
		{repositories, disposable} = req.git
		repositories.ref git_repo, refname
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

	app.put "/:git_repo(.*).git/:refname(refs/.*)", app.authorize("refs"), require("body-parser").json(), (req, res, next) ->
		for key in ["target", "message", "current"] when key not of req.body
			return next new BadRequestError "Missing parameter #{key}"

		{target, current, message, signature, symbolic} = req.body

		{git_repo, refname} = req.params
		{repositories, disposable} = req.git
		repositories.openOrInit git_repo
		.then -> repositories.ref git_repo, refname
		.then ([ref, repo]) ->
			if signature?
				try
					signature = git.Signature.create Signature
				catch err
					signature = null
			signature ?= git.Signature.default repo
			disposable signature
			if ref?
				if symbolic
					unless ref.isSymbolic()
						throw new BadRequestError "Not a symbolic reference"
					unless "#{ref.symbolicTarget()}" is target
						throw new BadRequestError "Wrong reference target"
					ref.symbolicSetTarget target, signature, message
				else
					unless "#{ref.target()}" is current
						throw new ConflictError "Non fast-forward change"
					target = git.Oid.fromString target
					ref.setTarget target, signature, message
			else
				if symbolic
					git.Reference.symbolicCreate repo, refname, target, 0, signature, message
				else
					target = git.Oid.fromString target
					git.Reference.create repo, refname, target, 0, signature, message
		.then (ref) ->
			disposable ref
			res.json ref
			next()
		.catch next
