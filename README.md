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
	auth: function (req, res, next, service) {
		next();
	},
	git_http_backend: {
		hooks: {
			'post-receive': function (req, res, next, changes) {
				// Do something after a push
				next();
			}
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

If set to an `object` it will be used as [git_http_backend.options](#git_http_backend-options).

### options.serve_static

> default: true

Enable the [blob service](#blob-service).

### options.auth

> default: noop

A middleware-like `(req, res, next, service)` callback to use to authorize requests.
All git-related parameters are assigned to `req.git` object.

To prevent an action the callback should throw an error that will trigger a
401 error response with the body set to the error's message.


### options.pattern

> default: `/.*/`

All repo names must match this pattern.

Any captured groups will be passed on to a `req.git.repo.args` object
for use in `options.auth`.

### options.auto_init

> default: true

Allow repos to be created on-demand.

If set to `false` only already existing repos will be used.
Use [options.auth](#optionsauth) and [options.pattern](#optionspattern) to control the creation of
new repos.

If set to an `object` it will be used as init_options for
new repos.

#### options.auto_init.bare

> default: true

#### options.auto_init.mkdir

> default: true

Create the dir for the repository if does not exist

#### options.auto_init.mkdirp

> default: true

Create the all required dirs for the repository path

#### options.auto_init.shared

> default: null

Permission mask to apply to the repository dir (git init --shared)

#### options.auto_init.head

> default: 'master'

The branch to which HEAD will point.

#### options.auto_init.origin

> default: null

A default origin remote to use for this remote.
Usually not needed as the repo will probably act as origin for others.


## Services

## `git_http_backend` service

Allow push/pull over http at

```
/path/to/repo.git
```

### git_http_backend options

####  git_http_backend.options.hooks

> default: false

Set to and object with key-value pairs of hook - callback.

The currenctly implemented hooks are

- `pre-receive: (req, res, next, changes)` With signature: `(req, res, next, changes)` where `changes` is an `Array` of `{before, after, ref}` objects. Passing an error to the `next` callback will effectively abort the push request. Use `res.write` to write info to the git client's `remote` output.

- `post-receive` With signature: `(req, res, next, changes)` where `changes` is an `Array` of `{before, after, ref}` objects. Use `res.write` to write info to the git client's `remote` output.

See [Server-Side Hooks][ServerSideHooks] for more info.

> #### How express-git handles hooks
>
> Git hooks normally are scripts running from the `GIT_DIR/hooks` dir.
> This is a difficult to configure method especially in the
> context of a web application where a lot of configuration
> bootstrap code would have to be replicated and reused in
> the hook script. And to make things worse per-request
> customization is practically impossible. Unless...
>
> #### Hook callbacks
>
> In order to overcome the above mentioned problems, express-git
> creates an ad-hoc tcp server where the hook scripts connect to
> passing their stdin to middleware-like `(req, res, next)`
> callbacks from the web application and uses the outcome
> of those callbacks to control the hook exit code.



#### git_http_backend.options.hooks_socket

> default: random port between 10000 and 14000 on windows or
> temporary socket file at `/tmp/express-git-TIMESTAMP.sock` on a proper OS.

Where the hook server should listen for hook script connections.

#### git_http_backend.options.git_exec

> default: `shelljs.which('git')`

For `git_http_backend` to work you need git installed on the server.
You can specify the git executable to use with the `git_exec` option.


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


### blob options

#### blob.options.max_age

> default: A year in seconds

The max_age Cache-Control header to use for served blobs


## The `req.git` object

Each request handled by express-git is assigned a frozen object `git` property with
the following properties:

### `req.git.project_root`

The base dir for all repos managed by this middleware

### `req.git.reponame`

The reponame for the current request relative to `git.project_root`

### `req.git.service`

The service name for this request

Possible service names are:

 - `blob` for raw file requests (if `options.serve_static` is enabled)
 - `receive-pack` for push requests
 - `upload-pack` for fetch requests
 - `init` for creating a non-existing repo (if `options.auto_init` is enabled)

### `req.git.rev`

The git [revision][revisions] for this request

### `req.git.path`

The path relative to the repo root for this request


[RepoInitOptions]: http://www.nodegit.org/api/repository_init_options/
[ServerSideHooks]: https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks#Server-Side-Hooks
[revisions]: https://git-scm.com/docs/revisions
