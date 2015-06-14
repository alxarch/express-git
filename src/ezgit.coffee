_path = require "path"
g = require "nodegit"
{assign} = require "./helpers"

{INIT_FLAG, INIT_MODE} = g.Repository
g.RepositoryInitOptions.fromObject = (options) ->
	opt = assign {}, g.Repository.INIT_DEFAULTS, options
	result = new g.RepositoryInitOptions()
	result.flags = 0
	unless opt.reinit
		result.flags |= INIT_FLAG.NO_REINIT
	unless opt.dotgit
		result.flags |= INIT_FLAG.NO_DOTGIT_DIR
	if opt.description
		result.description = opt.description
	result.initialHead = if opt.head then "#{opt.head}" else "master"
	if opt.origin
		result.originUrl = "#{opt.origin}"
	if opt.workdir
		result.workdirPath = "#{opt.workdir}"
	if opt.relative_gitlink
		result.flags |= INIT_FLAG.RELATIVE_GITLINK
	if opt.bare
		result.flags |= INIT_FLAG.BARE
	if opt.template
		result.flags |= INIT_FLAG.EXTERNAL_TEMPLATE
		result.templatePath = opt.template
	if opt.mkdirp or opt.mkdir
		result.flags |= INIT_FLAG.MKDIR
	if opt.mkdirp
		result.flags |= INIT_FLAG.MKPATH
	result.mode = 0
	switch opt.shared
		# nodegit.Repository.INIT_MODE values are wrong
		when "umask"
			result.mode = 0
		when "group"
			result.mode = 0x2775
		when "all"
			result.mode = 0x2777
		else
			result.mode |= "#{result.mode}" | 0
	result

g.Commit::_oidMethod = "id"
g.Blob::_oidMethod = "id"
g.Note::_oidMethod = "id"
g.OdbObject::_oidMethod = "id"
g.Object::_oidMethod = "id"
g.Tag::_oidMethod = "id"
g.Tree::_oidMethod = "id"
g.TreeEntry::_oidProperty = "oid"
g.Reference::_oidMethod = "target"
g.IndexEntry::_oidProperty = "id"
g.RebaseOperation::_oidProperty = "id"
g.DiffFile::_oidProperty = "id"

ZEROID = g.Oid.ZERO = g.Oid.fromString (new Array(40)).join "0"

g.Oid.fromAnything = (item) ->
	if item instanceof g.Oid
		item
	else if item._oidMethod
		item[item._oidMethod]()
	else if item._oidProperty
		item[item._oidProperty]
	else if item?
		g.Oid.fromString "#{item}"
	else
		g.Oid.ZERO

g.Repository.INIT_DEFAULTS = Object.freeze
	bare: yes
	reinit: yes
	template: null
	mkdir: yes
	mkdirp: no
	dotgit: yes
	head: null
	workdir: null
	origin: null
	relative_gitlink: no

g.Repository.OPEN_DEFAULTS = Object.freeze
	bare: no
	search: yes
	crossfs: no
g.Repository._open = g.Repository.open
g.Repository.open = (path, options={}) ->
	ceilings = ([].concat (options.ceilings or "")).join _path.delimiter
	options = assign {}, g.Repository.OPEN_DEFAULTS, options
	flags = 0
	unless options.search
		flags |= @OPEN_FLAG.OPEN_NO_SEARCH
	if options.bare
		flags |= @OPEN_FLAG.OPEN_BARE
	if options.crossfs
		flags |= @OPEN_FLAG.OPEN_CROSS_FS

	@openExt path, flags, ceilings

g.Repository._init = g.Repository.init
g.Repository.init = (path, options={}) ->
	@initExt path, g.RepositoryInitOptions.fromObject options

asrev = g.Revparse.toSpec = (value) ->
	switch typeof value
		when "string"
			value
		when "number"
			"HEAD@{#{value | 0}}"
		when "object"
			if not value
				"HEAD"
			if value instanceof Date
				"HEAD@{#{value.toISOString()}}"
			else
				{id, rev, tag, ref, branch, date, path, offset, search, upstream, type} = value
				result = "#{id or rev or tag or ref or branch or 'HEAD'}"
				if upstream and "#{branch}" is result
					result = "#{branch}@{upstream}"

				if offset
					result = "#{result}@{#{offset | 0}}"

				if date
					result = "#{result}@{#{date}}"

				if path
					result = "#{result}:#{path.replace /^\/+/, ''}"
				else if search
					result= "#{result}:/#{search}"
				else if type
					result = "#{result}^{#{type}}"

				result

g.Revparse._single = g.Revparse.single
g.Revparse.single = (repo, where) -> g.Revparse._single repo, @toSpec where

assign g.Repository::,
	find: (where) -> g.Revparse.single @, where

	createRef: (name, target, options={}) ->
		oid = g.Oid.fromAnything target
		force = if options.force then 1 else 0
		sig = options.signature or Signature.default @
		g.Reference.create @, name, oid, force, sig, message or ""

Object.defineProperty g.Revwalk::, 'repo',
	get: -> @repository()

g.Tree::toJSON = ->
	id: "#{@id()}"
	type: "tree"
	path: if typeof @path is "string" then @path else undefined
	entries: @entries().map (entry) ->
		id: "#{entry.oid()}"
		filename: "#{entry.filename()}"
		type: if entry.isBlob() then "blob" else "tree"

g.Signature::toJSON = ->
	name: @name
	email: @email
g.Commit::toJSON = ->
	id: "#{@id()}"
	type: "commit"
	tree: "#{@treeId()}"
	parents: @parents().map (p) -> "#{p}"
	date: @date()
	committer: "#{@committer()}"
	author: "#{@author()}"
	header: "#{@rawHeader()}"
	message: "#{@message()}"

module.exports = g
