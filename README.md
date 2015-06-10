# express-git
Express middleware that acts as a git-http-backend

Usage:

```javascript

var express = require("express");
var git = require("express-git");
var app = express();
app.use("/git", git({
	git_project_root: "repos/",
	auto_init: true
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

Which will create an empty repo at `repos/foo.git` to which you can
pull and push as usual.

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

### `req.git.changes`

The changes for a receive-pack hook (see [Hooks](#Hooks))

## Hooks

Git hooks are scripts running from the gitdir/hooks dir.
This is a difficult to configure method especially in the
context of a web application where a lot of configuration
bootstrap code would have to be replicated and reused in
the hook script. And to make things worse per-request
customization is practically impossible. Unless...

### Hook callbacks

In order to overcome the above mentioned problems, express-git
creates an ad-hoc tcp server where the hook scripts connect to
passing their stdin to middleware-like `(req, res, next)`
callbacks from the web application and uses the outcome
of those callbacks to control the hook exit code.

### Implemented hooks

#### pre-receive

Changes can be found under `req.git.changes` and is an `Array`
of `{before, after, ref}` objects. Passing an error
to the `next` callback will abort the request.

#### post-receive

Changes can be found under `req.git.changes` and is an `Array`
of `{before, after, ref}` objects.

See [Server-Side Hooks][ServerSideHooks] for more info.

## Options

### options.git_project_root

The base dir for repositories.

### options.serve_static

> default: true

Serve files from git repos.

You can access all files at `/path/to/repo.git/path/to/file`.
To access a file in a ref other than HEAD use
`/path/to/repo.git/blob/refspec:path/to/file`.

### options.auto_init

> default: true

Automatically create non-existing repositories

### options.authorize

> default: noop

A middleware-like `(req, res, next)` callback to use to authorize requests.
All git-related params are assigned to `req.git` object.

To prevent an action the callback should throw an error that will triger a
401 error response with the body set to the error's message.


### options.pre_receive

A middleware-like `(req, res, next)` pre-receive hook callback.
See [Hooks](#hooks)


### options.post_receive

A middleware-like `(req, res, next)` pre-receive hook callback.
See [Hooks](#hooks)

### options.pattern

> default: `/.*/`

All repo names must match this pattern.

Any captured groups will be passed on to a `req.git.repoargs` object
for use in `options.authorize` and `options.init_options` callbacks.

### options.init_options

To manage the init option for the auto created repos you can use
the `init_options` option that should be an object.

#### options.init_options.bare

> default: true

#### options.init_options.template

> default: express-git/templates

The git template path to use for a repo.

*BEWARE:* hook callbacks are implemented with
pre-receive and post-receive hooks in the default
express-git template. Setting a template path without
restoring these hooks will disable hook callbacks.


#### options.init_options.mkdir

> default: true

Create the dir for the repository if does not exist

#### options.init_options.mkdirp

> default: true

Create the all required dirs for the repository path

#### options.init_options.shared

> default: null

Permission mask to apply to the repository dir (git init --shared)

#### options.init_options.head

> default: 'master'

The branch to which HEAD will point.

#### options.init_options.origin

> default: null

A default origin remote to use for this remote.
Usually not needed as the repo will probably act as origin for others.


### options.hooks_socket

> default: random port between 10000 and 14000 on windows or
> temporary socket file at `/tmp/express-git-TIMESTAMP.sock` on a proper OS.

Where the hook server should listen for hook script connections.

### options.git_exec

> default: shelljs.which('git')

For `express-git` to work you need git installed on the server.
You can specify the git exectable to use with the `git_exec` option.


[RepoInitOptions]: http://www.nodegit.org/api/repository_init_options/
[ServerSideHooks]: https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks#Server-Side-Hooks
[revisions]: https://git-scm.com/docs/revisions
