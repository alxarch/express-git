# express-git
Express middleware that acts as a git-http-backend

Usage:

```javascript

var express = require("express");
var expressGit = require("express-git");
var app = express();
app.use("/git", expressGit.serve("path/torepos/", {
	auto_init: true,
	serve_static: true,
	auth: function (service, next) {
		// Authorize a service
		// this.req holds the request object
		// this.res holds the response object

		next();
	},
	hooks: {
		'post-receive': function (changes, next) {
			// Do something after a push
			// this.req holds the request object
			// this.res holds the response object
			next();
		}
	}
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

Enable the [blob service](#blob-service).

####  options.hooks

> default: {}

Set to and object with key-value pairs of hook - callback.
All hook callbacks take a callback as the last argument for
asynchronous hook logic.
All hook callbacks will be bound to an object so that
`this.req` is the request object and
`this.res` is the response object.

The currenctly implemented hooks are

- `pre-init: (repo, callback)` Where `repo` is the name of the repo to be created.
Specify individual repo `init_options` with `callback(null, options)`. See [Init Options](#init-options).
Prevent the initialization of the repo by passing an error to the callback.

- `post-init: (repo, callback)` Where `repo` is a `nodegit.Repository` object for the new repo.

- `pre-receive: (changes, callback)` Where `changes` is an `Array` of `{before, after, ref}` objects. Passing an error to the callback will prevent the push request.

- `update: (change, callback)` Where `change` is a `{before, after, ref}` object. Passing an error to the callback will prevent the push for this specific ref.

- `post-receive: (changes, callback)` Where `changes` is an `Array` of `{before, after, ref}` objects. Any error passed to the callback will be reported to the client but will not prevent the request.

See [Git Hooks][Git Hooks] for more info.

### options.auth

> default: noop

A `(service, callback)` hook to use to authorize requests.
As with hooks `this.req` and `this.res` will be bound to the request and response objects.	
All git-related parameters are assigned to `this.req.git` object.
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

The max_age Cache-Control header to use for served blobs

### options.git_executable

> default: `shelljs.which('git')`

For `git_http_backend` service to work you need git installed on the server.
You can specify the git executable to use with the `git_executable` option.


## Services

## `git_http_backend` service

Allow push/pull over http at

```
/path/to/repo.git
```


## `blob` service

Serve blobs from any ref at

```
/path/to/repo.git/(ref?)/blob/path/to/file.txt
```

The default ref is `HEAD`.

The blob's id is added as an `Etag` header tho the response. The `must-revalidate`
`Cache-Control` property is also added, because the ref of the blob-serving url
might point to a different blob after a repository modification. Thus the proxy
must revalidate the freshness on each request.

See [HTTP Cache Headers](http://www.mobify.com/blog/beginners-guide-to-http-cache-headers/) for more info.



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

 - `blob` for raw file requests (if `options.serve_static` is enabled)
 - `receive-pack` for push requests
 - `upload-pack` for fetch requests

### `req.git.auth`

A `(service)` callback for authorising services.

### `req.git.path`

The path relative to the repo root for this request

[Git Hooks]: http://git-scm.com/docs/githooks
[revisions]: https://git-scm.com/docs/revisions
