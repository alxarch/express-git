Busboy = require "busboy"

git = require "../ezgit"

{assign} = require "../helpers"
module.export = (app, options) ->

	app.post "/:reponame(.*).git/:refname(.*)?/commit/:path(.*)", app.authorize("commit"), (req, res, next) ->
		{open, using} = req.git
		{git_ref, path} = req.params
		etag = req.headers['x-commit-oid']
		repo = open reponame
		ref = repo.then (repo) ->
			if refname
				repo.getReference refname
			else
				repo.head()
		.then using
		commit = Promise.join repo, ref, (repo, ref) ->
			oid = ref.target()
			unless "#{oid}" is etag
				throw new ConflictError "Non ff commit"
			repo.getCommit(oid)
		.then using

		tree = commit.then (commit) -> commit.getTree().then using

		index = Promise.join tree, repo.index().then(using), (tree, index) ->
				index.clear()
				ok = index.readTree tree
				unless ok is 0
					throw new Error "Index cannot read commit tree"
				index

		Promise.join repo, index, commit, tree, ref, (repo, index, parent, tree, ref) ->
			repo.setWorkdir workdir
			new Promise (resolve, reject) ->

				bb = new Busboy headers: req.headers
				files = []
				bb.on "file", (fieldname, file) ->
					m = fieldname.match /^file:\/*(.*)/
					return unless m?
					path = m[1]
					return unless path
					dest = _path.join workdir, path
					p = mkdirp _path.dirname dest
					.then ->
						p = promistream file
						file.pipe fs.createWriteStream dest
						p
					.then -> index.addByPath path

					files.push p

				commit_data = {}

				bb.on "field", (fieldname, value) ->
					commit_data[fieldname] = value

				bb.on "finish", ->
					Promise.all files
					.then -> index.writeTree()
					.then (tree) ->
						repo.commit
							parents: [parent]
							tree: tree
							ref: ref
							message: commit_data.message
							author: commit_data.author
							committer: commit_data.committer
				.then (commit) ->
					res.json commit
				.then -> next()
				.catch next

			req.pipe bb

		.catch next