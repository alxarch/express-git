#TODO: hooks
Busboy = require "busboy"
Promise = require "bluebird"
_path = require "path"
{httpify} = require "../helpers"
os = require "os"
{createWriteStream} = require "fs"
rimraf = Promise.promisify require "rimraf"
mkdirp = Promise.promisify require "mkdirp"

module.exports = (app, options) ->
	{ConflictError, BadRequestError} = app.errors
	{git} = app

	app.post "/:reponame(.*).git/:refname(.*)?/commit/:path(.*)?", app.authorize("commit"), (req, res, next) ->
		{using, open} = req.git
		{reponame, refname, path} = req.params
		etag = req.headers['x-parent-id'] or req.query.parent or "#{git.Oid.ZERO}"
		repo = open reponame
		checkref = ->
			repo.then (repo) ->
				if repo.isEmpty()
					null
				else if refname
					repo.getReference refname
				else
					repo.head()
			.catch httpify 404
			.then using
			.then (ref) ->
				if ref? and "#{ref.target()}" isnt etag
					throw new ConflictError
				ref

		commit = Promise.join repo, checkref(), (repo, ref) ->
			if ref then repo.getCommit ref.target() else null
		.then using

		tree = commit
			.then (commit) -> commit?.getTree()
			.then using
			.then (tree) ->
				return tree unless path
				tree?.entryByPath path
				.then using
				.then (entry) ->
					if entry.isBlob()
						throw new BadRequestError()
					tree
				.catch -> tree
			.then using

		index = Promise.join repo, tree, (repo, tree) ->
			repo.index()
			.then using
			.then (index) ->
				index.clear()
				if tree
					index.readTree tree
				index

		workdir = _path.join os.tmpdir(), "express-git-#{new Date().getTime()}"
		Promise.join repo, commit, index, mkdirp(workdir), (repo, parent, index) ->
			repo.setWorkdir workdir, 0
			bb = new Busboy headers: req.headers
			files = []
			add = []
			bb.on "file", (filepath, file) ->
				filepath = _path.join (path or ""), filepath
				dest = _path.join workdir, filepath
				files.push new Promise (resolve, reject) ->
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

			finish = new Promise (resolve) -> bb.on "finish", -> resolve()
			req.pipe bb
			finish
			.then -> Promise.all files
			.then ->
				for r in remove
					index.removeByPath r
				for a in add
					index.addByPath a
				index.writeTree()
			.finally -> index.clear()
			.then (tree) -> repo.getTree tree
			.then using
			.then (tree) ->
				checkref().then (ref) ->
					repo.commit
						parents: [parent]
						ref: "#{ref or refname or 'HEAD'}"
						tree: tree
						author: commit.author
						commiter: commit.committer
						message: commit.message
		.then using
		.then (commit) -> next null, res.json commit
		.catch next
		.finally -> rimraf workdir
		.catch -> null
