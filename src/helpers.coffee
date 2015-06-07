os = require "os"
path = require "path"
assign = require "object-assign"
{spawn, exec} = require "child_process"
Promise = require "bluebird"

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
	exec: Promise.promisify exec
	spawn: (args...) ->
		if args[2]?
			stdio = args[2]?.stdio or null
			delete args[2].stdio
		else
			stdio = null

		cp = spawn args...
		# Node's child_process handling of stdio cannot handle req, res params in stdio
		if stdio?
			for s, i in ['stdin', 'stdout', 'stderr']
				switch stdio[i]
					when 'pipe'
						str = process[s]
					when 'ignore', null, false, undefined
						continue
					else
						str = stdio[i]
				if i > 0
					cp[s].pipe str
				else
					str.pipe cp[s]

		exit = new Promise (resolve, reject) ->
			cp.on "exit", (code) ->
				if code is 0
					resolve()
				else
					reject new Error "Child process exited with code #{code}"
		exit.process = cp
		exit
