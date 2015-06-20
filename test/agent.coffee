os = require "os"
_path = require "path"
expressGit = require "../src/index.coffee"
request = require "supertest"
module.exports = (options) ->
	GIT_PROJECT_ROOT = _path.join os.tmpdir(), "test-repos-#{new Date().getTime()}"
	app = expressGit.serve GIT_PROJECT_ROOT, options
	agent = request app


