{requestStream, assign, spawn, pktline} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
Promise = require "bluebird"

{PassThrough} = require "stream"
{Monitor, GitUpdateRequest, ZERO_PKT_LINE} = require "../stream"

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

		out = new Monitor "RESPONSE"
		stdin = new Monitor "STDIN"
		out.pipe res
		git_pack_stream = new GitUpdateRequest()
		git_pack_stream.on "error", next
		git_pack_stream.on "changes", (changes, capabilities) ->
			console.log arguments
			changeline = ({before, after, ref}) ->
				line = [before, after, ref].join " "
				if capabilities?
					line = "#{line}\0#{capabilities}\n"
					capabilities = null
					pktline line
				else
					pktline "#{line}\n"
			req.git.hook 'pre-receive', changes
			.then -> changes
			.map (change) ->
				req.git.hook 'update', change
				.then -> change
				.catch (err) ->
					out.write "Push to #{change.ref} rejected: #{err}"
					null
			.then (changes) ->
				changes = (c for c in changes when c?)
				return unless changes.length > 0
				git = spawn GIT_EXEC, args
				git.process.stdout.pipe out, end: no
				git.process.stderr.pipe out, end: no
				stdin.pipe git.process.stdin
				for change in changes
					stdin.write changeline change
				stdin.write ZERO_PKT_LINE
				git_pack_stream.pipe stdin
				git
				.then ->
					req.git.hook 'post-receive', changes
					.catch (err) -> out.write 'Post-receive hook failed'
				.then ->
					out.end()
					next()
			.catch next

		# Go git 'em!
		mon = new Monitor "GITPACKSTREAM"
		requestStream(req).pipe(mon).pipe git_pack_stream

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	app.get "/:git_repo(.*).git/:git_service(info/refs)", (req, res, next) ->
		{service, git_dir} = req.git
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			'Content-Type': "application/x-git-#{service}-advertisement"
		res.write pktline "# service=git-#{service}\n"
		res.write ZERO_PKT_LINE
		args = [service, '--stateless-rpc', '--advertise-refs', git_dir]
		stdio = ['ignore', res, 'pipe']
		spawn GIT_EXEC, args, {stdio}
		.catch next

	app
