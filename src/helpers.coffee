os = require "os"
path = require "path"

module.exports =
	socket: ->
		if os.platform() is "win32"
			# A random port between 10000 and 14000
			((Math.random() * 4000) + 10000) | 0
		else
			path.join os.tmpdir(), "express-git-hook-#{new Date().getTime()}.sock"
