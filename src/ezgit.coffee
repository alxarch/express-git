
path = require "path"
g = require "nodegit"
assign = require "object-assign"
{Transform, PassThrough} = require "stream"
zlib = require "zlib"
fs = require "fs"

class GitObjectReadStream extends Transform
	constructor: ->
		super
		stream = @
		@promise = new Promise (resolve, reject) =>
			@on "error", reject
			@on "ready", (type, size) ->
				stream.removeListener "error", reject
				resolve {stream, type, size}

	_transform: (chunk, encoding, callback) ->
		unless @header
			for c, i in chunk when c is 0
				break
			@header = "#{chunk.slice 0, i}"
			[type, size] = @header.split /\s+/
			@emit "ready", type, size
			chunk = chunk.slice i + 1
		@push chunk
		callback()

class OdbObject
	@wrap: (obj) ->
		if obj instanceof GitOdbObject
			obj
		else if obj instanceof g.OdbObject
			new OdbObject obj.id(), obj.type()
		else
			GitObject.wrap obj

	constructor: (id, type) ->
		@id = if id instanceof g.Oid then id.tostrS() else "#{id}"
		@type = if "number" is typeof type then g.Object.type2string type else "#{type}"

class GitObject extends OdbObject
	@wrap: (obj) ->
		if obj instanceof GitObject
			obj
		else if obj instanceof g.Object
			new GitObject obj
		else if obj instanceof g.Commit
			new Commit object
		else if obj instanceof g.Blob
			new Blob obj
		else if obj instanceof g.Tree
			new Tree obj
		else
			throw new TypeError "Invalid object type"

	baseClass: g.Object
	constructor: (@_obj) ->
		unless @_obj instanceof @baseClass
			throw new TypeError "Invalid object"
		super @_obj.id(), @type or @_obj.type()

	getRepository: -> Repository.wrap(@_obj.owner())
	getReadStream: -> @getRepository().createReadStream @id

class Blob extends GitObject
	@wrap: (obj) -> if obj instanceof Blob then obj else new Blob obj
	baseClass: g.Blob
	type: "blob"

class Tree extends GitObject
	@wrap: (obj) -> if obj instanceof Tree then obj else new Tree obj
	type: "tree"
	baseClass: g.Tree

class Entry
	Object.defineProperty Entry::, 'id', get: -> @_entry.sha()
	Object.defineProperty Entry::, 'path', get: -> @_entry.path()
	Object.defineProperty Entry::, 'type', get: -> if @_entry.isTree() then "tree" else "blob"
	constructor: (@_entry) ->
	getObject: ->
		if @_entry.isBlob()
			@_entry.getBlob().then Blob.wrap
		else if @entry.isTree()
			@_entry.getTree().then Tree.wrap
		else
			throw new TypeError "Invalid entry type"

class Commit extends GitObject
	Object.defineProperty Commit::, 'date', get: -> @_obj.date()
	Object.defineProperty Commit::, 'message', get: -> @_obj.message()
	Object.defineProperty Commit::, 'header', get: -> @_obj.rawHeader()
	Object.defineProperty Commit::, 'body', get: -> @_obj.rawMessage()
	type: "commit"
	baseClass: g.Commit
	@wrap: (obj) -> if obj instanceof Commit then obj else new Commit obj 
	getTree: -> @_obj.getTree().then Tree.wrap
	getEntry: (path) -> @_obj.getEntry(path).then (entry) -> new Entry entry

class Repository
	{INIT_FLAG, OPEN_FLAG} = g.Repository

	open_defaults =
		bare: no
		search: yes
		crossfs: no

	init_defaults =
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

	
	asoid = (oid) -> if oid instanceof g.Oid then oid else g.Oid.fromString "#{oid}"
	asopenrepo = (options) ->
		opt = assign {}, open_defaults, options
		flags = 0
		unless opt.search
			flags |= OPEN_FLAG.OPEN_NO_SEARCH
		if opt.bare
			flags |= OPEN_FLAG.OPEN_BARE
		if opt.crossfs
			flags |= OPEN_FLAG.OPEN_CROSS_FS
		flags

	asinitrepo = (options) ->
		opt = assign {}, init_defaults, options
		result = new g.RepositoryInitOptions()
		result.flags = 0
		unless opt.reinit
			result.flags |= INIT_FLAG.NO_REINIT
		unless opt.dotgit
			result.flags |= INIT_FLAG.NO_DOTGIT_DIR
		if opt.description
			result.description = opt.description
		result.initialHead = if opt.head then "#{opt.head}" else "refs/heads/master"
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
	
	Object.defineProperty @::, "path", get: -> @_repo.path()

	@wrap: (repo) -> if repo instanceof Repository then repo else new Repository repo
	@open: (path, options={}) ->
		ceilings = ([].concat (options.ceilings or "")).join path.delimiter
		g.Repository.openExt path, (asopenrepo options), ceilings
		.then (repo) -> new Repository repo

	@init: (path, options={}) ->
		Promise.resolve g.Repository.initExt path, asinitrepo options
		.then (repo) => @wrap repo
	
	constructor: (@_repo) ->
		unless @_repo instanceof g.Repository
			throw new TypeError "Invalid repo"

	getReference: (options={}) ->
		p =
			if "string" is typeof options and g.Reference.isValidName options
				@_repo.getReference options
			else if options.ref and g.Reference.isValidName options.ref
				@_repo.getReference options.ref
			else if options.tag
				@_repo.getReference "refs/tags/#{options.tag}"
			else if options.branch
				@_repo.getReference "refs/heads/#{options.branch}"
			else
				@_repo.head()
		p.then (ref) =>
			if not ref.isSymbolic()
				ref
			else if options.symbolic
				ref
			else
				@getReference ref.symbolicTarget()

	findByPath: (path, options={}) ->
		@getReference options
		.then (ref) => g.Commit.lookup @_repo, ref.target()
		.then (commit) -> commit.getEntry path
		.then (entry) =>
			g.Object.lookup @_repo, g.Oid.fromString(entry.sha()), g.Object.TYPE.ANY
		.then (obj) -> GitObject.wrap obj

	createReadStream: (oid) ->
		Promise.resolve path.join @_repo.path(0), "objects", oid[0..1], oid[2..]
		.then (loose) ->
			gstr = new GitObjectReadStream()
			fs.createReadStream loose
			.pipe zlib.createUnzip()
			.pipe gstr
			gstr.promise

		.catch (err) =>
			@_repo.odb()
			.then (odb) ->
				odb.read asoid oid
				.then (obj) ->
					stream = new PassThrough()
					type = obj.type()
					data = obj.data()
					size = data.length
					stream.end data
					{stream, type, size}

module.exports = ezgit = {
	Repository
	Commit
	Blob
	Tree
	Entry
	GitObject
	OdbObject
}
