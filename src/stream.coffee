{Transform} = require "stream"

ZERO_PKT_LINE = new Buffer "0000"
PACK = new Buffer "PACK"

class GitPackStream extends Transform
	constructor: ->
		super
		@pos = 0
		@buffer = null
	_transform: (chunk, encoding, callback) ->
		return callback null, chunk if @pos < 0
		buffer = if @buffer? then Buffer.concat [@buffer, chunk] else chunk
		while true
			end = @pos + 4
			if buffer.length < end
				@buffer = buffer
				break

			head = buffer.slice @pos, end
			if head.equals ZERO_PKT_LINE
				@pos = end
				end += 4
				unless PACK.equals buffer.slice @pos, end
					@emit "error", new Error "No pack header"
					@push null
					break
				@push ZERO_PKT_LINE
				@push PACK
				@push buffer.slice end
				@pos = -1
				@buffer = null
				break
			
			offset = parseInt "#{head}", 16
			if offset > 0
				@push buffer.slice @pos, @pos + offset
				@pos += offset
			else
				@emit "error", new Error "Invalid pkt line"
				@push null
				break
		callback()

class GitPktLines extends Transform
	_transform: (chunk, encoding, callback) ->
		size = chunk.length + 4
		head = new Buffer "0000#{size.toString 16}".substr -4, 4
		@push Buffer.concat [head, chunk]
		callback()
	_flush: (callback) ->
		@push ZERO_PKT_LINE

class GitReadPktLines extends Transform
	header: yes
	_transform: (chunk, encoding, callback) ->
		unless @header
			return callback()
		@header = chunk isnt ZERO_PKT_LINE
		if @header
			@push chunk.slice 4
		callback()

class GitReadPack extends Transform
	pack: no
	_transform: (chunk, encoding, callback) ->
		if @pack
			@push chunk
		else if chunk is PACK
			@pack = yes
		callback()

createGitPackStream = ->
	stream = new GitPackStream()
	stream.pktlines = new GitReadPktLines()
	stream.pack = new GitReadPack()
	stream.pipe stream.pktlines
	stream.pipe stream.pack
	stream

module.exports = {
	PACK
	ZERO_PKT_LINE
	GitPackStream
	GitPktLines
	GitReadPktLines
	GitReadPack
	createGitPackStream
}
