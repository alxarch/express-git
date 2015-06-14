os = require "os"
path = require "path"
{spawn, exec} = require "child_process"
Promise = require "bluebird"
assign = (base, others...) ->
	return base unless typeof base is "object"
	for obj in others when typeof obj is "object"
		for own key, value of obj
			base[key] = value
	base

zlib = require "zlib"

{UnsupportedMediaTypeError} = require "./errors"
module.exports =
	requestStream: (req) ->
		encoding = req.headers['content-encoding']?.toLowerCase() or 'identity'
		length = req.headers['content-length']
		switch encoding
			when "deflate"
				req.pipe zlib.createInflate()
			when "gzip"
				req.pipe zlib.createGunzip()
			when "identity"
				req.length = length
				req
			else
				throw new UnsupportedMediaTypeError "Unsuported encoding #{encoding}"

	assign: assign

	a2o: (arr) -> (-> arguments) arr...
	freeze: (args...) ->
		args.unshift {}
		Object.freeze assign.apply null, args
	exec: Promise.promisify exec
	isMiddleware: (m) ->
		typeof m is "function" or
		m instanceof express.Router or
		m instanceof express.Application
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
	pktline: (line) ->
		size = line.length + 4
		head = "0000#{size.toString 16}".substr -4, 4
		new Buffer "#{head}#{line}"
