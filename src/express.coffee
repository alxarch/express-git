mock = require "mockery"
mock.registerMock "path-to-regexp", require "path-to-regexp"
mock.enable
	warnOnUnregistered: no
	useCleanCache: yes
module.exports = require "express"
mock.disable()

