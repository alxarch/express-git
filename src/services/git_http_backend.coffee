{requestStream, assign, spawn, pktline} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
Promise = require "bluebird"

{PassThrough} = require "stream"
{GitUpdateRequest, ZERO_PKT_LINE} = require "../stream"

module.exports = (app, options={}) ->
	GIT_EXEC = options?.git_executable or which "git"
	headers = (service, type='result') ->
		'Pragma': 'no-cache'
		'Expires': (new Date '1900').toISOString()
		'Cache-Control': 'no-cache, max-age=0, must-revalidate'
		'Content-Type': "application/x-git-#{service.replace 'git-', ''}-#{type}"

	app.post ":repo(.*).git/git-upload-pack", app.authorize("upload-pack"), (req, res, next) ->
		res.set headers "upload-pack"
		req.git.open req.params.repo
		.then (repo) ->
			args = ['upload-pack', '--stateless-rpc', repo.path()]
			spawn GIT_EXEC, args, stdio: [req, res, res]
		.then -> next()
		.catch next

	app.post ":repo(.*).git/git-receive-pack", app.authorize("receive-pack"), (req, res, next) ->
		{open} = req.git
		res.set headers "receive-pack"
		repo = open req.params.repo
		pack = new Promise (resolve, reject) ->
			git = new GitUpdateRequest()
			git.on "error", reject
			git.on "changes", ->
				git.removeListener "error", reject
				resolve git
			requestStream(req).pipe git
		Promise.join repo, pack, (repo, pack) ->
			{capabilities, changes} = pack
			changeline = ({before, after, ref}) ->
				line = [before, after, ref].join " "
				if capabilities
					line = "#{line}\0#{capabilities}"
					capabilities = null
				pktline "#{line}\n"

			app.emit "pre-receive", repo, changes
			.then -> Promise.all changes.map (change, i) ->
				app.emit "update", repo, change
				.then -> change
				.catch (err) -> null
			.then (changes) ->

				changes = (c for c in changes when c?)
				return unless changes.length > 0
				git = spawn GIT_EXEC, ["receive-pack", "--stateless-rpc", repo.path()]

				{stdin, stdout, stderr} = git.process
				stdout.pipe res, end: no
				stderr.pipe res, end: no
				for change in changes
					stdin.write changeline change
				stdin.write ZERO_PKT_LINE

				pack.pipe stdin

				git
			.then -> app.emit "post-receive", repo, changes
		.finally -> res.end()
		.then -> next()
		.catch next

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	app.get "/:repo(.*).git/info/refs", app.authorize("advertise-refs"), (req, res, next) ->
		{service} = req.query

		unless service in ["git-receive-pack", "git-upload-pack"]
			return next new BadRequestError

		service = service.replace 'git-', ''

		req.git.open req.params.repo
		.then (repo) ->
			res.set headers service, "advertisement"
			res.write pktline "# service=git-#{service}\n"
			res.write ZERO_PKT_LINE
			args = [service, '--stateless-rpc', '--advertise-refs', repo.path()]
			spawn GIT_EXEC, args, stdio: ['ignore', res, 'pipe']
		.then -> next()
		.catch next
