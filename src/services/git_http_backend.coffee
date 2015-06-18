{requestStream, assign, spawn, pktline} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
Promise = require "bluebird"

{PassThrough} = require "stream"
{GitUpdateRequest, ZERO_PKT_LINE} = require "../stream"

module.exports = (app, options={}) ->
	GIT_EXEC = options?.git_executable or which "git"

	app.post ":reponame(.*).git/git-:service(receive-pack|upload-pack)", (req, res, next) ->
		{service, reponame} = req.params
		{open, hook, auth} = req.git

		auth service
		.then -> open reponame
		.then (repo) ->
			res.set
				'Pragma': 'no-cache'
				'Expires': (new Date '1900').toISOString()
				'Cache-Control': 'no-cache, max-age=0, must-revalidate'
				'Content-Type': "application/x-git-#{service}-result"
			args = [service, '--stateless-rpc', repo.path()]
			unless service is "receive-pack"
				stdio = [requestStream(req), res, "pipe"]
				return spawn GIT_EXEC, args, {stdio}
			git_pack_stream = new GitUpdateRequest()
			git_pack_stream.on "error", next
			git_pack_stream.on "changes", (changes, capabilities) ->
				changeline = ({before, after, ref}) ->
					line = [before, after, ref].join " "
					if capabilities?
						line = "#{line}\0#{capabilities}\n"
						capabilities = null
						pktline line
					else
						pktline "#{line}\n"
				hook 'pre-receive', changes
				.then -> changes
				.map (change) ->
					hook 'update', change
					.then -> change
					.catch (err) ->
						res.write "Push to #{change.ref} rejected: #{err}"
						null
				.then (changes) ->
					changes = (c for c in changes when c?)
					return unless changes.length > 0
					git = spawn GIT_EXEC, args
					git.process.stdout.pipe res, end: no
					git.process.stderr.pipe res, end: no
					for change in changes
						git.process.stdin.write changeline change
					git.process.stdin.write ZERO_PKT_LINE
					git_pack_stream.pipe git.process.stdin
					git
					.then ->
						hook 'post-receive', changes
						.catch (err) -> res.write 'Post-receive hook failed'
					.then -> res.end()
			requestStream(req).pipe git_pack_stream
		.then -> next()
		.catch next

		# Go git 'em!

	# Ref advertisement for push/pull operations
	# via git receive-pack/upload-pack commands
	app.get "/:reponame(.*).git/info/refs", (req, res, next) ->
		{service} = req.query
		if service in ["git-receive-pack", "git-upload-pack"]
			service = service.replace "git-", ""
		else
			return next new BadRequestError "Invalid service"

		{reponame} = req.params
		{auth, open} = req.git
		auth service
		.then -> open reponame
		.then (repo) ->
			res.set
				'Pragma': 'no-cache'
				'Expires': (new Date '1900').toISOString()
				'Cache-Control': 'no-cache, max-age=0, must-revalidate'
				'Content-Type': "application/x-git-#{service}-advertisement"
			res.write pktline "# service=git-#{service}\n"
			res.write ZERO_PKT_LINE
			args = [service, '--stateless-rpc', '--advertise-refs', repo.path()]
			stdio = ['ignore', res, 'pipe']
			spawn GIT_EXEC, args, {stdio}
		.catch next

	app
