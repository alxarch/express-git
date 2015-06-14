{Transform} = require "stream"

ZERO_PKT_LINE = new Buffer "0000"
PACK = new Buffer "PACK"

class GitUpdateRequest extends Transform
	constructor: ->
		super
		@pos = 0
		@buffer = null
		@changes = []
		@capabilities = null

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
				@emit "changes", @changes, @capabilities
				@push buffer.slice end
				@buffer = null
				@pos = -1
				break
			
			offset = parseInt "#{head}", 16
			if offset > 0
				@pos += offset
				line = buffer.toString "utf8", end, @pos
				unless @capabilities?
					[line, capabilities] = line.split "\0"
				[before, after, ref] = line.split " "
				@changes.push {before, after, ref}
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
		callback()

module.exports = {
	PACK
	ZERO_PKT_LINE
	GitUpdateRequest
	GitPktLines
}
