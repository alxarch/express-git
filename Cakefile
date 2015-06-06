{exec} = require "child_process"
task "build", "Compile coffee-script", ->
	exec "coffee -c -m -o lib/ src/*.coffee", (err, stdout, stderr) ->
		process.stdout.write stdout
		process.stderr.write stderr
		if err
			console.error err
			process.exit 1
		process.exit 0
