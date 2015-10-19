expressGit = require "../src/index"
Promise = require "bluebird"
rimraf = Promise.promisify require "rimraf"
os = require "os"
path = require "path"
supertest = require "supertest-as-promised"
{assert} = require "chai"
{cat} = require "shelljs"
GIT_PROJECT_ROOT = path.join os.tmpdir(), "express-git-test-#{new Date().getTime()}"
app = expressGit.serve GIT_PROJECT_ROOT, {}
agent = supertest app

describe "POST /*.git/commit", ->
	FILE = "#{__dirname}/data/test.txt"
	FILEDATA = cat FILE

	after -> rimraf GIT_PROJECT_ROOT
	it "creates a repo on first commit", ->
		agent.post "/test.git/commit"
		.field "message", "Commit message"
		.field "author", "John Doe <john@doe.com>"
		.attach "foo/bar/test.txt", FILE
		.attach "foo/test.txt", FILE
		.expect 200

	it "browses the commit", ->
		agent.get "/test.git/commit"
		.expect (res) ->
			assert res.body.author.email is "john@doe.com"
			assert res.body.committer.email is "john@doe.com"
			assert res.body.id.length is 40
			assert res.body.message is "Commit message"

	it "Can browse the created blobs", ->
		blobA= agent.get "/test.git/blob/foo/test.txt"
		.expect
			id: "980a0d5f19a64b4b30a87d4206aade58726b60e3"
			path: "foo/test.txt"
			type: "blob"
			mime: "text/plain"
			size: FILEDATA.length
			contents: FILEDATA
			encoding: "utf8"
			binary: no
			truncated: no
			filename: "test.txt"
		blobB =  agent.get "/test.git/blob/foo/bar/test.txt"
		.expect
			id: "980a0d5f19a64b4b30a87d4206aade58726b60e3"
			path: "foo/bar/test.txt"
			mime: "text/plain"
			size: FILEDATA.length
			contents: FILEDATA
			encoding: "utf8"
			binary: no
			truncated: no
			type: "blob"
			filename: "test.txt"

		Promise.join blobA, blobB

	it "Can browse the created dirs", ->
		dirA = agent.get "/test.git/tree/foo/bar"
		.expect
			id: "376357880b048faf2553da6bc58ae820cea3690a"
			type: "tree"
			path: "foo/bar"
			name: "bar"
			entries: [
				{
					id: "980a0d5f19a64b4b30a87d4206aade58726b60e3"
					path: "foo/bar/test.txt"
					type: "blob"
					filename: "test.txt"
					attr: "100644"
				}
			]
		dirB =  agent.get "/test.git/tree/foo"
		.expect
			id: "9868d83040a01353c11c7aec46364e817ba51643"
			type: "tree"
			path: "foo"
			name: "foo"
			entries: [
				{
					id: "376357880b048faf2553da6bc58ae820cea3690a"
					type: "tree"
					path: "foo/bar"
					filename: "bar"
					attr: "40000"
				}
				{
					id: "980a0d5f19a64b4b30a87d4206aade58726b60e3"
					path: "foo/test.txt"
					type: "blob"
					filename: "test.txt"
					attr: "100644"
				}
			]
		Promise.join dirA, dirB

	it "finds the created files", ->
		fileA = agent.get "/test.git/raw/foo/bar/test.txt"
		.expect 200
		.expect FILEDATA
		fileB = agent.get "/test.git/raw/foo/test.txt"
		.expect 200
		.expect FILEDATA
		Promise.join fileA, fileB

	it "should return 404 on non-existing blob browses", ->
		agent.get "/test.git/blob/foo.txt"
		.expect 404

	it "should return 400 on browsing dirs as blob", ->
		agent.get "/test.git/blob/foo"
		.expect 400

	it "Should return 404 on non-existent repos", ->
		agent.get "/test-1.git/commit"
		.expect 404

