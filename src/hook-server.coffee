{createServer} = require "net"
path = require "path"
Promise = require "bluebird"

# fs = require "fs"

init = ->
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

module.exports = (socket) ->
	new Promise (resolve, reject) ->
		try
			srv = init()
			socket = parseInt(socket) or path.resolve "#{socket}"
			srv.listen socket, -> resolve srv
		catch err
			reject err
