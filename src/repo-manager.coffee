_ = require "lodash"
Promise = require "bluebird"
_path = require "path"
git = require "./ezgit"

class RepoManager
	module.exports = @
	constructor: (@root, options={}) ->
		@options = _.defaults {}, options,
			pattern: /.*/
			auto_init: yes
			init_options: {}

	parse: (path) ->
		name = path.replace /\.git$/, ""
		match = name.match @options.pattern
		Promise.resolve match or []
			.then ([name, params...]) =>
				unless name?
					throw new Error "Invalid repo path '#{path}'"
				git_dir = _path.join @root, name
				[name, params, git_dir]

	refopen: (path, refname) ->
		@open path
		.then (repo) ->
			if refname
				ref = repo.getReference refname
			else
				ref = repo.head()
			ref.then (ref) -> [repo, ref]

	openOrInit: (path, options) ->
		@open path
		.then (repo) -> [repo, no]
		.catch (err) =>
			@init path, options
			.then (repo) -> [repo, yes]

	open: (path) ->
		@parse path
		.then ([name, params, git_dir]) =>
			git.Repository.open git_dir,
				bare: yes
				ceilings: [@root]
			.tap (repo) -> _.assign repo, {name, params, git_dir}

	init: (path, options={}) ->
		@parse path
		.then ([name, params, git_dir]) =>
			git.Repository.init git_dir, options
			.tap (repo) -> _.assign repo, {name, params, git_dir}
	

