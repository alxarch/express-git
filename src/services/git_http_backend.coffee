{socket, assign, spawn, pkt_line} = require "../helpers"
{which} = require "shelljs"
_path = require "path"
uuid = require "uuid"
Promise = require "bluebird"

GIT_HTTP_BACKEND_DEFAULTS =
	hooks: {}
	hooks_socket: socket()
	git_executable: which "git"
{Transform, Writable, PassThrough} = require "stream"

class GitReceivePackSniffer extends Transform
	EMPTY = new Buffer()
	constructor: (options) ->
		options = assign {}, options, readableObjectMode: yes
		super options
		@pos = -1
		@offset = 0
		@buffer = EMPTY

	_transform: (chunk, encoding, callback) ->
		unless @buffer?
			return do callback

		@buffer = Buffer.concat [@buffer, chunk]
		try
			pos = @buffer.readUint32BE @offset
		catch RangeError
			return do callback
		if pos > 0
			line = @buffer.slice @offset + 4, @offset + pos
			@offset += pos

		else if pos is 0
			@buffer = null



		callback()




createHookServer = Promise.promisify (socket, next) ->
	{createServer} = require "net"
	srv = createServer {pauseOnConnect: yes}, (conn) ->
		callback = (err) ->
			code = new Buffer [
				if err then (parseInt(err) or 1) else 0
			]
			conn.write code

		conn.on "readable", () ->
			data = conn.read()
			unless data?
				return callback()
			try
				{id, name, changes} = JSON.parse "#{data}"
			catch err
				return callback 4


			try
				srv.emit "#{id}:#{name}", changes, callback
			catch err
				console.error err.stack
				callback 3
	socket = parseInt(socket) or _path.resolve "#{socket}"
	try
		srv.listen socket, -> next null, srv
	catch err
		next err

module.exports = (app, options) ->
	options = assign {}, GIT_HTTP_BACKEND_DEFAULTS, options

	GIT_EXEC = options.git_executable

	if options.hooks
		GIT_HOOK_SOCKET = options.hooks_socket
		# Initialize the hooks server
		hooks = createHookServer GIT_HOOK_SOCKET

		# Setup the EXPRESS_GIT_HOOK env var passed to hook scripts
		hook = require.resolve '../hook'
		EXPRESS_GIT_HOOK = [hook]
		# Allow ".coffee" extensions for development
		if ".coffee" is _path.extname hook
			EXPRESS_GIT_HOOK.unshift require.resolve "coffee-script/register"
		EXPRESS_GIT_HOOK = EXPRESS_GIT_HOOK.join _path.delimiter
	else
		hooks = Promise.resolve no

	app.post ":git_repo(.*).git/git-:git_service(receive-pack|upload-pack)", (req, res, next) ->
		{repo, service} = req.git
		res.set
			'Pragma': 'no-cache'
			'Expires': (new Date '1900').toISOString()
			'Cache-Control': 'no-cache, max-age=0, must-revalidate'
			'Content-Type': "application/x-git-#{service}-result"
		hooks.then (hooks) ->
			env = {}
			if hooks and service is "receive-pack"
				GIT_HOOK_ID = uuid.v4()
				env = {EXPRESS_GIT_HOOK, GIT_HOOK_SOCKET, GIT_HOOK_ID}
				{post_receive, pre_receive} = options

				if typeof pre_receive is "function"
					# Respond only after pre-receive hook
					hooks.once "#{GIT_HOOK_ID}:pre-receive", (changes, callback) ->
						req.git = freeze req.git, {changes}
						pre_receive req, res, callback

				if typeof post_receive is "function"
					hooks.once "#{GIT_HOOK_ID}:post-receive", (changes, callback) ->
						req.git = freeze req.git, {changes}
						post_receive req, res, callback

			args = [service, '--stateless-rpc', repo.path()]
			stdio = [req, res, 'pipe']
			spawn GIT_EXEC, args, {env, stdio}
		.catch next

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
