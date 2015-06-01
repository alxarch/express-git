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

### options.auto_init

> default: yes

Automatically create non-existing repositories


### options.repo_init_options

To manage the init option for the auto created repos you can use
the `repo_init_options` option that should be

- a [RepositoryInitOptions][RepoInitOptions] object

or

- a `(repo_path, req)` callback returning a [RepositoryInitOptions][RepoInitOptions] object

### options.git_exec

> default: shelljs.which('git')

For `express-git` to work you need git installed on the server.
You can specify the git exectable to use with the `git_exec` option.


[RepoInitOptions]: http://www.nodegit.org/api/repository_init_options/
