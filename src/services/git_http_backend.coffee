{requestStream, assign, spawn, pkt_line} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
Promise = require "bluebird"

{PassThrough} = require "stream"
{GitUpdateRequest, GitPktLines} = require "../stream"

module.exports = (app, options={}) ->
	GIT_EXEC = options?.git_executable or which "git"

	app.post ":git_repo(.*).git/git-:git_service(receive-pack|upload-pack)", (req, res, next) ->
		{repo, service} = req.git
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			'Content-Type': "application/x-git-#{service}-result"

		args = [service, '--stateless-rpc', repo.path()]
		unless service is "receive-pack"
			stdio = [requestStream(req), res, "pipe"]
			spawn GIT_EXEC, args, {stdio}
			.then -> next()
			.catch next
			return

		git_pack_stream = new GitUpdateRequest()
		git_pack_stream.on "error", next
		git_pack_stream.on "changes", (changes, capabilities) ->
			changeline = ({before, after, ref}) ->
				line = [before, after, ref].join " "
				if capabilities?
					line = "#{line}\0#{capabilities}\n"
					capabilities = null
					line
				else
					"#{line}\n"
			req.git.hook 'pre-receive', changes
			.then -> changes
			.map (change) ->
				req.git.hook 'update', change
				.then -> change
				.catch (err) ->
					res.write "Push to #{change.ref} rejected: #{err}"
					null
			.then (changes) ->
				changes = (c for c in changes when c?)
				return unless changes.length > 0

				buffer = new PassThrough()
				pktlines = new GitPktLines()
				pktlines.pipe buffer, end: no
				for change in changes
					pktlines.write changeline change
				pktlines.end()
				git_pack_stream.pipe buffer
				spawn GIT_EXEC, args, stdio: [buffer, res, "pipe"]
				.then ->
					req.git.hook 'post-receive', changes
					.catch (err) -> console.error err
			.then -> next()
			.catch next

		# Go git 'em!
		requestStream(req).pipe git_pack_stream

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	app.get "/:git_repo(.*).git/:git_service(info/refs)", (req, res, next) ->
		{service, git_dir} = req.git
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			'Content-Type': "application/x-git-#{service}-advertisement"
		res.write pkt_line "# service=git-#{service}\n0000"
		args = [service, '--stateless-rpc', '--advertise-refs', git_dir]
		stdio = ['ignore', res, 'pipe']
		spawn GIT_EXEC, args, {stdio}
		.catch next

	app
