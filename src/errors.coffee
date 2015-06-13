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

NonHttpError = (err) -> not err.status
module.exports = {
	HttpError
	ServerError
	BadRequestError
	UnauthorizedError
	NotFoundError
	NonHttpError
	UnsupportedMediaTypeError
}
