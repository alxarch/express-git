class HttpError extends Error
	name: "HttpError"
	constructor: (@message) ->
		if @status >= 500
			Error.captureStackTrace @
	toJSON: ->
		message: @message
		statusCode: @status
		error: @name

class ServerError extends HttpError
	status: 500
	name: "ServerError"
	message: "Internal Server Error"

class NotFoundError extends HttpError
	status: 404
	name: "NotFoundError"
	message: "Not Found"

class BadRequestError extends HttpError
	status: 400
	name: "BadRequestError"
	message: "Bad Request Error"

class UnauthorizedError extends HttpError
	status: 401
	name: "UnauthorizedError"
	message: "Not Authorized"

class UnsupportedMediaTypeError extends HttpError
	status: 415
	name: "UnsupportedMediaTypeError"
	message: "Unsupported Media Type"

class NotModified extends HttpError
	status: 304
	name: "NotModified"
	message: null

class ConflictError extends HttpError
	status: 409
	name: "Conflict"
	message: "Conflict"

httpErrorHandler = (err, req, res, next) ->
	status = parseInt err.status or err.statusCode
	if status and not res.headersSent
		res.status status
		if status < 400
			res.end()
		else if req.accepts "json"
			res.json err
		else if res.message
			res.send res.message
			res.end()
		else
			res.end()
		next()
	else
		next err

NonHttpError = (err) -> not err.status

module.exports = {
	HttpError
	NotModified
	ServerError
	BadRequestError
	UnauthorizedError
	NotFoundError
	NonHttpError
	httpErrorHandler
	UnsupportedMediaTypeError
	ConflictError
}
