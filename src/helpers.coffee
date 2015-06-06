os = require "os"
path = require "path"
assign = require "object-assign"

module.exports =
	assign: assign
	pkt_line: (line) ->
		unless line instanceof Buffer
			line = new Buffer "#{line}"
		prefix = new Buffer "0000#{line.length.toString 16}".substr -4, 4
		Buffer.concat [prefix, line]
	freeze: (args...) ->
		args.unshift {}
		Object.freeze assign.apply null, args
	socket: ->
		if os.platform() is "win32"
			# A random port between 10000 and 14000
			((Math.random() * 4000) + 10000) | 0
		else
			path.join os.tmpdir(), "express-git-hook-#{new Date().getTime()}.sock"
