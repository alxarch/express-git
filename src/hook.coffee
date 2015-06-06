{Transform} = require "stream"
path = require "path"

class SplitLines extends Transform
	EMPTY = new Buffer([])
	NEWLINE = 10
	constructor: ->
		super
		@buffer = EMPTY
	_transform: (chunk, encoding, callback) ->
		buffer = Buffer.concat [@buffer, chunk]
		offset = 0
		for n, i in buffer when n is NEWLINE
			@push buffer.slice offset, i++
			offset = i
		@buffer = if offset < i then buffer.slice offset else EMPTY
		callback()

	_flush: (callback) ->
		if @buffer.length > 0
			@push @buffer
		callback()

class Changes extends Transform
	constructor: (options={}) ->
		options.readableObjectMode = yes
		super options
	_transform: (chunk, encoding, callback) ->
		[before, after, ref] = "#{chunk}".split /\s+/
		@push {before, after, ref}
		callback()

module.exports = (hook_name) ->

	socket = process.env.GIT_HOOK_SOCKET
	id = process.env.GIT_HOOK_ID

	process.exit() unless id and socket

	{createConnection} = require "net"
	options = {}
	socket = parseInt(socket) or path.resolve("#{socket}")
	if typeof socket is "number"
		options.port = socket
	else
		options.path = socket

	conn = createConnection options, ->
		conn.on "data", (data) ->
			process.exit data.readUInt8()

	hookdata =
		name: hook_name
		id: id
		changes: []

	changes = process.stdin.pipe(new SplitLines()).pipe(new Changes())
	changes.on "data", (c) -> hookdata.changes.push c
	changes.on "end", ->
		conn.write JSON.stringify hookdata
		conn.end()
