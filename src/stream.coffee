{Transform} = require "stream"

ZERO_PKT_LINE = new Buffer "0000"
PACK = new Buffer "PACK"

incoming.on "changes", (changes, capabilities) ->
	changeline = ({before, after, ref}) ->
		line = [before, after, ref].join " "
		if capabilities
			line = "#{line}\0#{capabilities}"
			capabilities = null
		"#{line}\n"

	hook "pre-receive", changes
	.then -> changes
	.map (change) ->
		hook "update", change
		.then -> change
		.catch -> null
	.then -> (c for c in changes when c?)
	.then (changes) ->
		return unless changes.length
		git = spawn GIT_EXEC, args
		{stdin, stdout, stderr} = git.process
		for c in changes

			if capabilities then ""
				stdin.write pktline if capabilities then ""

			git.process.stdin.write pktline change
		git.process.stdin.writwriteChanges changes, capabilities

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
					[line, @capabilities] = line.split "\0"
				[before, after, ref] = line.split " "
				@changes.push {before, after, ref}
			else
				@emit "error", new Error "Invalid pkt line"
				@push null
				break
		callback()

module.exports = {
	PACK
	ZERO_PKT_LINE
	GitUpdateRequest
}
