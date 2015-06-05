# express-git
Express middleware that acts as a git-http-backend

Usage:

```javascript

var express = require("express");
var git= require("express-git");
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

## Options

### options.git_project_root

The base dir for repositories.

### options.serve_static

> default: true

Serve files from git repos.

You can access all files at `/path/to/repo.git/~raw/path/to/file`.
To access a file in a ref other than HEAD use 
`/path/to/repo.git/refs/heads/foo/~raw/path/to/file`.

### options.auto_init

> default: true

Automatically create non-existing repositories

### options.authorize

> default: noop

A callback to use to authorize requests.
The signature is `(service, repo_path, req)`.
Possible service names are:

 - `raw` for raw file requests (if `option.serve_static` is enabled)
 - `receive-pack` for pull requests
 - `upload-pack` for push requests
 - `init` for creating a non-existing repo (if `option.auto_init` is enabled)

To prevent an action the callback should throw an error that will triger a
401 error response with the body set to the error's message.

### options.init_options

To manage the init option for the auto created repos you can use
the `init_options` option that should be an object.

#### options.init_options.bare

> default: true

#### options.init_options.template

> default: null

#### options.init_options.mkdir

> default: true

Create the dir for the repository if does not exist

#### options.init_options.mkdirp

> default: true

Create the all required dirs for the repository path

#### options.init_options.shared

> default: null

Permission mask to apply to the repo dir (git init --shared)

#### options.init_options.head

> default: 'master'

The branch to which HEAD will point.

#### options.init_options.origin

> default: null

A default origin remote to use for this remote.
Usually not needed as the repo will probably act as origin for others.


### options.git_exec

> default: shelljs.which('git')

For `express-git` to work you need git installed on the server.
You can specify the git exectable to use with the `git_exec` option.


[RepoInitOptions]: http://www.nodegit.org/api/repository_init_options/
