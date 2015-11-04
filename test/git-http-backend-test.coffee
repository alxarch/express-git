require "shelljs/global"
Promise = require "bluebird"
execp = Promise.promisify require("child_process").exec
expressGit = require "../src/index"
assert = require "assert"

describe "git-http-backend service", ->
	DATA_DIR = "#{__dirname}/data/repo"
	TMP_DIR = GIT_PROJECT_ROOT = SOURCE_DIR = DEST_DIR = null
	PORT = 20000 + (new Date().getTime() % 10000) | 0
	REPO = "testrepo-#{new Date().getTime()}"
	before ->
		mkdir TMP_DIR = "tmp/express-git-test-#{new Date().getTime()}"
		mkdir GIT_PROJECT_ROOT = "#{TMP_DIR}/repos"
		mkdir SOURCE_DIR = "#{TMP_DIR}/source"
		mkdir DEST_DIR = "#{TMP_DIR}/dest"
	app = null
	server = null
	before ->
		app = expressGit.serve GIT_PROJECT_ROOT, {}
		server = app.listen PORT

	it "Clones empty repos", ->
		cd SOURCE_DIR
		execp "git clone http://localhost:#{PORT}/#{REPO}.git"
		.then -> assert.ok (test "-d", REPO), "Cloned empty repo"

	it "Pushes refs", ->
		cd REPO
		cp "#{DATA_DIR}/README.md", "."
		exec "git add README.md"
		exec "git commit -m 'Initial commit'"
		execp "git push"

	it "Clones ", ->
		cd DEST_DIR
		execp "git clone http://localhost:#{PORT}/#{REPO}.git"
		.then ->
			assert.ok (test "-d", REPO), "Cloned repo"
			cd REPO
			assert.ok (test "-f", "README.md"), "Cloned repo"
			assert.equal (cat "README.md"), "# Foo Bar Baz\n", "README is ok"

	it "Pushes from non-empty repo", ->
		cd DEST_DIR
		cd REPO
		cp "-R", "#{DATA_DIR}/foo", "."
		exec "git add foo"
		exec "git commit -m 'Add foo'"
		execp "git push"

	it "Pulls changes", ->
		cd SOURCE_DIR
		cd REPO
		execp "git pull"
		.then ->
			assert.ok test "-d", "foo"
			assert.ok test "-d", "foo/bar"
			assert.ok test "-f", "foo/bar/baz.txt"
			assert.equal (cat "foo/bar/baz.txt"), "foo bar baz\n"

	after -> server.close()
	after -> rm "-rf", TMP_DIR
