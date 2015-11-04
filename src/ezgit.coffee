_path = require "path"
Promise = require "bluebird"
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

	Promise.resolve @openExt path, flags, ceilings

g.Repository._init = g.Repository.init
g.Repository.init = (path, options={}) ->
	Promise.resolve @initExt path, g.RepositoryInitOptions.fromObject options

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
	headRefName: ->
		if @isEmpty()
			@head().catch (err) -> err.message.replace /.*'([^']+)'.*/, '$1'
		else
			@head().then (head) ->
				name = head.name()
				head.free()
				name

	commit: (options) ->
		{ref, tree} = options
		if ref instanceof g.Reference
			ref = ref.name()
		else if ref
			ref = "#{ref}"
		else
			ref = null

		unless tree instanceof g.Tree
			tree = g.Tree.lookup @, g.Oid.fromString "#{tree}"

		author = g.Signature.create options.author
		committer = g.Signature.create options.committer

		parents = Promise.resolve (options.parents or []).filter (a) -> a
		.map (parent) =>
			if parent instanceof g.Commit
				parent
			else
				@getCommit "#{parent}"

		message = options.message or "Commit #{new Date()}"

		Promise.join ref, tree, parents, (ref, tree, parents) =>
			author ?= @defaultSignature()
			committer ?= @defaultSignature()
			parent_count = parents.length
			g.Commit.create @, ref, author, committer, null, message, tree, parent_count, parents
		.then (oid) =>
			g.Commit.lookup @, oid

	find: (where) -> g.Revparse.single @, where

	createRef: (name, target, options={}) ->
		oid = g.Oid.fromAnything target
		force = if options.force then 1 else 0
		sig = options.signature or Signature.default @
		g.Reference.create @, name, oid, force, sig, message or ""

# Object.defineProperty g.Revwalk::, 'repo',
# 	get: -> @repository()

g.Blob::toJSON = ->
	id: "#{@id()}"
	size: "#{@rawsize()}"
	binary: if @isBinary() then yes else no
	filemode: "#{@filemode().toString 8}"

g.TreeEntry::toJSON = ->
	id: @oid()
	path: @path()
	type: if @isBlob() then "blob" else "tree"
	filename: @filename()
	attr: @attr().toString 8

g.Tree::toJSON = ->
	id: "#{@id()}"
	type: "tree"
	path: if typeof @path is "string" then @path else undefined
	entries: @entries().map (entry) ->
		id: "#{entry.oid()}"
		filename: "#{entry.filename()}"
		type: if entry.isBlob() then "blob" else "tree"

trim = (value) -> if typeof value is "string" then value.replace /(^[<\s]+|[\s>]+$)/g, "" else value

g.Time.parse = (date) ->
	d = new Date date
	time = d.getTime()
	unless time
		d = new Date()
		time = d.getTime()
	offset = d.getTimezoneOffset()
	time = time / 1000 | 0
	{time, offset}

g.Signature._create = g.Signature.create
g.Signature.create = (args...) ->
	switch args.length
		when 4
			[name, email, time, offset] = args
		when 3
			[name, email, date] = args
			{time, offset} = g.Time.parse date
		when 2
			[signature, date] = args
			{time, offset} = g.Time.parse date
			if typeof signature is "string"
				{name, email} = g.Signature.parse signature
			else if signature instanceof g.Signature
				name = signature.name()
				email = signature.email()
			else if typeof signature is "object"
				{name, email} = signature
		when 1
			[signature] = args
			if signature instanceof g.Signature
				return signature
			else if typeof signature is "string"
				{name, email} = g.Signature.parse signature
				{time, offset} = g.Time.parse null
			else if typeof signature is "object"
				{name, email, date} = signature
				{time, offset} = g.Time.parse date
	time = parseInt time
	offset = parseInt offset
	name = trim name
	email = trim email
	unless name and time and offset
		throw new TypeError "Invalid signature arguments"
	g.Signature._create name, email, time, offset

g.Signature.parse = (signature) ->
	m = "#{signature}".match /^([^<]+)(?:<([^>]+)>)?$/
	unless m?
		throw new TypeError "Cannot parse signature"
	[name, email] = m[1..]
	{name, email}

g.Signature.fromString = (signature, date) ->
	{name, email} = @parse signature
	{time, offset} = g.Time.parse date
	email = trim email
	name = trim name
	@create name, email, time, offset

g.Signature::getDate = ->
	d = new Date()
	d.setTime @when().time() * 1000
	d

g.Signature::toJSON = ->
	name: @name()
	email: @email()
	date: @getDate()

g.Commit::toJSON = ->
	id: "#{@id()}"
	type: "commit"
	tree: "#{@treeId()}"
	parents: @parents().map (p) -> "#{p}"
	date: @date()
	committer: @committer().toJSON()
	author: @author().toJSON()
	message: "#{@message()}"

g.Reference.find = (repo, refname="HEAD") ->
	ref =
		if @isValidName refname
		then @lookup(repo, refname).catch -> null
		else @dwim repo, refname
	ref.then (r) =>
		if r?.isSymbolic()
			refname = r.symbolicTarget()
			@find repo, refname
			.catch -> r
		else
			ref

module.exports = g
