{requestStream, assign, spawn, pkt_line} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
Promise = require "bluebird"

GIT_HTTP_BACKEND_DEFAULTS =
	hooks: null
	git_executable: which "git"
{PassThrough} = require "stream"
{PACK, createGitPackStream, GitPktLines} = require "../stream"

promisifyHooks = (hooks) ->
	return no unless typeof hooks is "object"

	result =
		'pre-receive': Promise.resolve
		'post-receive': Promise.resolve
		'update': Promise.resolve

	for own hook, callback of hooks when result[hook] and typeof callback is "function"
		result[hook] = Promise.promisify callback
	result

module.exports = (app, options) ->
	options = assign {}, GIT_HTTP_BACKEND_DEFAULTS, options

	GIT_EXEC = options.git_executable
	GIT_HOOKS = promisifyHooks options.hooks

	app.post ":git_repo(.*).git/git-:git_service(receive-pack|upload-pack)", (req, res, next) ->
		{repo, service} = req.git
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			'Content-Type': "application/x-git-#{service}-result"

		args = [service, '--stateless-rpc', repo.path()]
		unless GIT_HOOKS and service is "receive-pack"
			stdio = [requestStream(req), res, "pipe"]
			spawn GIT_EXEC, args, {stdio}
			.then -> next()
			.catch next
			return

		git_pack_stream = createGitPackStream()
		git_pack_stream.on "error", next
		git_pack_stream.pktlines.on "error", next
		git_pack_stream.pack.on "error", next
		changes = []
		capabilities = null
		changeline = ({before, after, ref}) ->
			line = [before, after, ref].join " "
			console.dir ref
			if capabilities?
				line = "#{line}\0#{capabilities}\n"
				capabilities = null
				line
			else
				"#{line}\n"

		git_pack_stream.pktlines.on "data", (pktline) ->
			pktline = "#{pktline}"
			if capabilities?
				line = pktline
			else
				[line, capabilities] = pktline.split "\0"
			[before, after, ref] = line.split " "
			changes.push {before, after, ref}

		git_pack_stream.pktlines.on "end", ->
			GIT_HOOKS['pre-receive'] changes, req, res
			.then -> changes
			.map (change) ->
				GIT_HOOKS['update'] change, req, res
				.then -> change
				.catch (err) ->
					res.write "Push to #{change.ref} rejected via express-git hook: #{err}"
					null
			.then (changes) ->
				changes = (c for c in changes when c?)
				return unless changes.length > 0

				buffer = new PassThrough()
				pktlines = new GitPktLines()
				pktlines.pipe buffer
				for change in changes when change?
					pktlines.write changeline change
				pktlines.end()
				buffer.write PACK
				git_pack_stream.pack.pipe buffer
				stdio = [buffer, res, "pipe"]
				spawn GIT_EXEC, args, {stdio}
				.then -> GIT_HOOKS['post-receive'] changes, res, res
				.catch console.error
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
