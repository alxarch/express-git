expressGit = require "../src/index"
Promise = require "bluebird"
os = require "os"
path = require "path"
supertest = require "supertest-as-promised"
{cat} = require "shelljs"
GIT_PROJECT_ROOT = path.join os.tmpdir(), "express-git-test-#{new Date().getTime()}"
app = expressGit.serve GIT_PROJECT_ROOT, {}
agent = supertest app

describe "POST /*.git/commit", ->
	it "creates a repo on first commit", ->
		FILE = "#{__dirname}/data/test.txt"
		agent.post "/test.git/commit"
		.field "message", "Commit message"
		.field "author", "John Doe <john@doe.com>"
		.attach "foo/bar/test.txt", FILE
		.attach "foo/test.txt", FILE
		.expect 200
		.then ->
			fileA = agent.get "/test.git/raw/foo/bar/test.txt"
			.expect 200
			.expect cat FILE
			fileB = agent.get "/test.git/raw/foo/test.txt"
			.expect 200
			.expect cat FILE
			Promise.join fileA, fileB
