_ = require "lodash"
Promise = require "bluebird"
_path = require "path"
git = require "./ezgit"

EventEmitter = require "events-as-promised"
using = (handler, chain) -> git.using chain, handler
DEFAULT_PATTERN = /.*/

class RepoManager extends EventEmitter
	module.exports = @

	constructor: (@root, @disposables=[], @options={}) ->
	
	disposable: (obj) ->
		@disposables.push obj
		obj

	parse: (path) ->
		name = path.replace /\.git$/, ""
		pattern = @options?.pattern or DEFAULT_PATTERN
		match = name.match pattern
		Promise.resolve match or []
			.then ([name, params...]) =>
				unless name?
					throw new Error "Invalid repo path '#{path}'"
				git_dir = _path.join @root, name
				[name, params, git_dir]

	ref: (path, refname) ->
		@open path
		.then (repo) =>
			if not repo?
				[null, null]
			else if refname
				repo.getReference refname
				.then @disposable
				.then (ref) -> [ref, repo]
			else
				repo.head()
				.then @disposable
				.then (ref) -> [ref, repo]

	openOrInit: (path, options) ->
		@open path
		.then (repo) =>
			if repo?
				[repo, no]
			else if @options.auto_init isnt no
				@init path, options
				.then (repo) -> [repo, yes]
			else
				[null, no]

	open: (path) ->
		@parse path
		.then ([name, params, git_dir]) =>
			git.Repository.open git_dir,
				bare: yes
				ceilings: [@root]
			.then @disposable
			.catch -> null
			.then (repo) -> _.assign repo, {name, params, git_dir}

	init: (path, options={}) ->
		@parse path
		.then ([name, params, git_dir]) =>
			init_options = _.assign {}, @options.init_options, options
			@emit "pre-init", name, params, init_options
			.then -> git.Repository.init git_dir, options
			.then @disposable
			.catch -> null
			.then (repo) -> _.assign repo, {name, params, git_dir}
			.then (repo) =>
				if repo?
					@emit "post-init", repo
					.then -> repo
				else
					repo

	blob: (reponame, oid, handler) ->
		@open reponame
		.then (repo) =>
			repo.getBlob oid
			.then @disposable
			.then (blob) -> [blob, repo]

	entry: (reponame, refname, path, handler) ->
		@commit reponame, refname
		.then ([commit, ref, repo]) ->
			unless commit?
				return [null, null, null, null]
			commit.getEntry path
			.then @disposable
			.then (entry) -> [entry, commit, ref, repo]

	commit: (reponame, refname, handler) ->
		@ref reponame, refname
		.then ([ref, repo]) =>
			unless repo?
				return [null, null, null]
			repo.getCommit ref.target()
			.then @disposable
			.then (commit) -> [commit, ref, repo]
