agent = require "./agent"
request = agent {}
describe "POST /*.git/commit", ->
	it "creates a repo on first commit", (done) ->
		request.post "/test.git/commit"
		.field "message", "Commit message"
		.field "author", "John Doe <john@doe.com>"
		.attach "foo/bar/test.txt", "#{__dirname}/data/test.txt"
		.expect 200
		.end (err, res) ->
			if err
				return done err
			done()


