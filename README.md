Express middleware that acts as a git-http-backend

Usage:

```javascript

var express = require("express");
var expressGit = require("express-git");
var app = express();
app.use("/git", expressGit.serve("path/torepos/", {
	auto_init: true,
	serve_static: true,
	authorize: function (service, req, next) {
		// Authorize a service
		next();
	}
});

app.on('post-receive', function (repo, changes) {
	// Do something after a push
	next();
});

app.listen(3000);

```

After which you can

```sh
git clone http://localhost:3000/git/foo.git
cd foo
echo "# Hello Git" > README.md
git add README.md
git commit -m "Initial commit"
git push
```

Which will create an empty repo at `path/torepos/foo.git` to which you can
pull and push as usual.


## Options

### options.git_http_backend

> default: true

Enable the [git_http_backend service](#git_http_backend-service).

If set to `false` push/pull operations will not be possible over `http`.

### options.serve_static

> default: true

Enable the [raw service](#raw-service).

### options.browse

> default: true

Enable the [browse service](#browse-service).


### options.allow_commits

> default: true

Enable the [commit service](#commit-service).


### options.refs

> default: true

Enable the [refs service](#refs-service).

### options.authorize

> default: noop

A `(service, req, callback)` hook to use to authorize requests.
To prevent an action, pass an error to the callback.

### options.pattern

> default: `/.*/`

All repo names must match this pattern.

Any captured groups will be passed on to a `req.git.repo.args` object
for use in `options.auth`.

### options.auto_init

> default: true

Allow repos to be created on-demand.

If set to `false` only already existing repos will be used.

### options.init_options

> default: {}

Default `init_options` for new repos. See [Init options](#init-options)
To override per-repo init_options use `hooks['pre-init']`.

### options.max_age

> default: A year in seconds

The `max_age` `Cache-Control` header to use for served blobs


### options.max_size

> default: 2K

The max size of truncated blob data to include in [browse](#browse-service) requests.

### options.git_executable

> default: `shelljs.which('git')`

For `git_http_backend` service to work you need git installed on the server.
You can specify the git executable to use with the `git_executable` option.


##  Hooks

Git hooks are implemented using events. Async event handlers are supported
via Promises. Event cancellation is possible (for cancellable events)
by rejecting a promise or throwing an error.

Register event listeners via `expressGit.on(hook, handler)`

Events to listen for:

### `pre-init: (name, params, init_options)`

> Cancellable: yes

Where `name` is the name of the repo to be created and `params` is a parameter
array parsed via `options.pattern`. The 3rd argument `init_options`
is an object that you can modify to change the [initialization options](#init-options) for this repo.
You can return a promise if you need to perform an async operation.
Rejecting will prevent the initialization of the repo.

See [Git Hooks][Git Hooks] for more info.

### `post-init: (repo, )`

> Cancellable: no

Where `repo` is a `nodegit.Repository` object for the new repo.

### `pre-receive: (repo, changes)`

> Cancellable: yes

Where `changes` is an `Array` of `{before, after, ref}` objects.
Rejecting will prevent the push request.

### `update: (repo, change)`

> Cancellable: yes

Where `change` is a `{before, after, ref}` object.
Rejecting will prevent the push for this specific ref.

### `post-receive: (repo, changes)`

> Cancellable: no

Where `changes` is an `Array` of `{before, after, ref}` objects.
Rejecting will be report the error to the client but will not prevent the request.


### `pre-commit: (repo, commit)`

> Cancellable: yes

Where `repo` is the `nodegit.Repository` instance where the commit will happen,
`commit` is an `object` with `ref, message, author, tree, parents, committer` keys.
Rejecting will abort the commit.


### `post-commit: (repo, changes)`

> Cancellable: no

Where `repo` is the `nodegit.Repository` instance where the commit happened
and `commit` is an object with commit details.



## Services

## `git_http_backend` service

Allow push/pull over http at

```
GET /path/to/repo.git/info/refs?service=(git-receive-pack|git-upload-pack)
POST /path/to/repo.git/(git-receive-pack|git-upload-pack)
```


## `raw` service

Serve blobs from any ref at

```
GET /path/to/repo.git/(ref?)/raw/path/to/file.txt
```

The default ref is `HEAD`.

The blob's id is added as an `Etag` header tho the response. The `must-revalidate`
`Cache-Control` property is also added, because the ref of the blob-serving url
might point to a different blob after a repository modification. Thus the proxy
must revalidate the freshness on each request.

See [HTTP Cache Headers](http://www.mobify.com/blog/beginners-guide-to-http-cache-headers/) for more info.


## `browse` service

Browse repositories as json

```
GET /path/to/repo.git/(ref?)/blob/(path/to/file.txt)
GET /path/to/repo.git/(ref?)/tree/(path/to/dir)?
GET /path/to/repo.git/(ref?)/commit/
GET /path/to/repo.git/(ref?)/object/(object-id)
```

The default ref is `HEAD`.


## `commit` service

Git commits using multipart forms

```
POST /path/to/repo.git/(ref?)/commit/(path/to/basepath)?parent=(object-id)
```

> Commit parent id should either be specified by an `x-parent-id` header
> or the `parent` query parameter. It will default to the empty object id (40 zeros)

If the provided parent id is not the current target of the ref,
the commit will be rejected with a `409 Confict` error response.


### Form fields

 - **message** The commit message
 - **author** The commit author (accepts `name <email>` format)
 - **committer** The committer (accepts `name <email>` format), fallback to author
 - **created_at** The of the commit creation (author date)
 - **remove** (can repeated be multiple times) The paths to remove (stemming from basepath if provided). Removals occur before additions.

### File fields

All form file fields will be added, using the fieldname as path.
(`basepath` url parameter will be prepended to this path)

## `refs` service

Git ref manipulation via REST

```
PUT /path/to/repo.git/(ref)
DELETE /path/to/repo.git/(ref)
```

### JSON fields

 - **target** (str) The target to set the ref to point to
 - **current** (str) The current ref target (to spot conflicts)
 - **message** (str) The commit message
 - **symbolic** (bool)
 - **signature {name, email, date}** A signature to use for the commit


## Init options

### init_options.bare

> default: true

### init_options.mkdir

> default: true

Create the dir for the repository if does not exist

### init_options.mkdirp

> default: true

Create the all required dirs for the repository path

### init_options.shared

> default: null

Permission mask to apply to the repository dir (git init --shared)

### init_options.head

> default: 'master'

The branch to which HEAD will point.

### init_options.origin

> default: null

A default origin remote to use for this remote.
Usually not needed as the repo will probably act as origin for others.

### init_options.template

> default: null

A GIT_TEMPLATE_PATH to use for the repo.


## The `req.git` object

Each request handled by express-git is assigned a frozen object `git` property with
the following properties:

### `req.git.hook`

A `(name, args...)` function trigerring hooks


### `req.git.repo`

The current repository for this request

### `req.git.service`

The service name for this request

Possible service names are:

 - `raw` for raw file requests (if `options.serve_static` is enabled)
 - `browse` for json browsing of the repos  (if `options.browse` is enabled)
 - `commit` for commits over http  (if `options.allow_commits` is enabled)
 - `receive-pack` for push requests
 - `upload-pack` for fetch requests
 - `advertise-refs` for ref advertisement before push/pull requests

### `req.git.auth`

A `(service)` callback for authorising services.

### `req.git.path`

The path relative to the repo root for this request

[Git Hooks]: http://git-scm.com/docs/githooks
[revisions]: https://git-scm.com/docs/revisions
