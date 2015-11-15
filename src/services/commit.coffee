Busboy = require "busboy"
Promise = require "bluebird"
_path = require "path"
{workdir, httpify} = require "../helpers"
{createWriteStream} = require "fs"
rimraf = Promise.promisify require "rimraf"
mkdirp = Promise.promisify require "mkdirp"
git = require "../ezgit"

processCommitForm = (req, workdir, path) ->
	bb = new Busboy headers: req.headers
	files = []
	add = []
	bb.on "file", (filepath, file) ->
		filepath = _path.join (path or ""), filepath
		dest = _path.join workdir, filepath
		files.push (mkdirp _path.dirname dest).then ->
			new Promise (resolve, reject) ->
				file.on "end", ->
					add.push filepath
					resolve()
				file.on "error", reject
				file.pipe createWriteStream dest

	commit = {}
	remove = []
	bb.on "field", (fieldname, value) ->
		if fieldname is "remove"
			remove.push value
		else
			commit[fieldname] = value

	form = new Promise (resolve) ->
		bb.on "finish", ->
			Promise.all files
			.then -> resolve {add, remove, commit}
	req.pipe bb
	form

module.exports = (app, options) ->
	{ConflictError, BadRequestError} = app.errors

	app.post "/:git_repo(.*).git/:refname(.*)?/commit/:path(.*)?", app.authorize("commit"), (req, res, next) ->
		{git_repo, refname, path} = req.params
		{repositories, disposable} = req.git
		etag = req.headers['x-parent-id'] or req.query?.parent or "#{git.Oid.ZERO}"
		WORKDIR = workdir()
		form = processCommitForm req, WORKDIR, path
		repo = repositories.openOrInit(git_repo).then ([repo]) -> repo
		ref = repo.then (repo) ->
			refname ?= "HEAD"
			git.Reference.find repo, refname
			.then disposable
			.catch httpify 404
			.then (ref) ->
				if ref?.isSymbolic()
					refname = ref.symbolicTarget()
					ref = null
				else if ref?
					refname = ref.name()
				if ref? and "#{ref.target()}" isnt etag
					throw new ConflictError
				ref

		parent = Promise.join repo, ref, (repo, ref) ->
			if ref?
				disposable repo.getCommit ref.target()
			else
				null
		tree = parent.then (parent) ->
			parent?.getTree()
			.then disposable
			.then (tree) ->
				unless path
					return tree
				tree?.entryByPath path
				.then disposable
				.then (entry) ->
					if entry.isBlob()
						throw new BadRequestError()
					tree

		index = Promise.join repo, tree, (repo, tree) ->
			repo.index()
			.then disposable
			.then (index) ->
				index.clear()
				if tree
					index.readTree tree
				index

		disposable author = Promise.join repo, form, (repo, {commit}) ->
			{created_at, author} = commit
			if author
			then git.Signature.create author, new Date created_at
			else repo.defaultSignature()

		disposable committer = Promise.join author, form, (author, {commit}) ->
			{committer} = commit
			if committer
			then git.Signature.create committer, new Date()
			else git.Signature.create author, new Date()

		addremove = Promise.join repo, index, form, (repo, index, {remove, add}) ->
			repo.setWorkdir WORKDIR, 0
			for r in remove
				index.removeByPath r
			for a in add
				index.addByPath a
			index.writeTree()
			.then disposable

		Promise.all [
			repo
			form
			author
			committer
			parent
			addremove
		]
		.then ([repo, form, author, committer, parent, tree]) ->
			commit =
				# Make everything modifiable
				parents: if parent then ["#{parent.id()}" ] else []
				ref: refname
				tree: "#{tree}"
				author: author.toJSON()
				committer: committer.toJSON()
				message: form.commit.message
			app.emit "pre-commit", repo, commit
			.then -> repo.commit commit
			.then disposable
			.then (result) ->
				commit.id = "#{result.id()}"
				app.emit "post-commit", repo, commit
				.then -> result
			.then (commit) -> res.json commit
		.finally -> rimraf WORKDIR
		.then -> next()
		.catch next

for own key, value of {processCommitForm}
	module.exports[key] = value
