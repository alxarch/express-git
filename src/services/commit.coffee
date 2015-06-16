#TODO: hooks
Busboy = require "busboy"
Promise = require "bluebird"
_path = require "path"
os = require "os"
{createWriteStream} = require "fs"
rimraf = Promise.promisify require "rimraf"
mkdirp = Promise.promisify require "mkdirp"

module.exports = (app, options) ->
	{ConflictError, BadRequestError} = app.errors

	app.post "/:git_repo(.*).git/:refname(.*)?/:git_service(commit)/:path(.*)?", (req, res, next) ->
		{repo, cleanup} = req.git
		{refname, path} = req.params
		etag = req.headers['x-commit-oid']
		checkref = ->
			repo.then (repo) ->
				if refname
					repo.getReference(refname) 
				else
					repo.head()
			.then cleanup
			.then (ref) ->
				unless "#{ref.target()}" is etag
					throw new ConflictError
				ref
		commit = Promise.join repo, checkref(), (repo, ref) ->
			repo.getCommit ref.target()
			.then cleanup
	
		tree = commit
			.then (commit) -> commit.getTree()
			.then cleanup
			.then (tree) ->
				return tree unless path
				tree.entryByPath path
				.then cleanup
				.catch null
				.then (entry) ->
					if entry? and entry.isBlob()
						throw new BadRequestError()
					tree

		index = Promise.join repo, tree, (repo, tree) ->
			repo.index()
			.then cleanup
			.then (index) ->
				index.clear()
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
			.then cleanup
			.then (tree) ->
				checkref().then (ref) ->
					repo.commit
						parents: [parent]
						ref: ref
						tree: tree
						author: commit.author
						commiter: commit.committer
						message: commit.message
		.then (commit) -> res.json commit
		.then -> next()
		.catch next
		.finally -> rimraf workdir
		.catch -> null
