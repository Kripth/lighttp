module lighttp.util;

import std.array : Appender;
import std.conv : to, ConvException;
import std.json : JSONValue;
import std.regex : ctRegex;
import std.string : toUpper, toLower, split, join, strip, indexOf;
import std.traits : EnumMembers;
import std.uri : encode, decode;

import libasync : NetworkAddress;

import url : URL;

/**
 * Indicates the status of an HTTP response.
 */
struct Status {
	
	/**
	 * HTTP response status code.
	 */
	uint code;
	
	/**
	 * Additional short description of the status code.
	 */
	string message;
	
	bool opEquals(uint code) {
		return this.code == code;
	}
	
	bool opEquals(Status status) {
		return this.opEquals(status.code);
	}
	
	/**
	 * Concatenates the status code and the message into
	 * a string.
	 * Example:
	 * ---
	 * assert(Status(200, "OK").toString() == "200 OK");
	 * ---
	 */
	string toString() {
		return this.code.to!string ~ " " ~ this.message;
	}
	
	/**
	 * Creates a status from a known list of codes/messages.
	 * Example:
	 * ---
	 * assert(Status.get(200).message == "OK");
	 * ---
	 */
	public static Status get(uint code) {
		foreach(statusCode ; [EnumMembers!StatusCodes]) {
			if(code == statusCode.code) return statusCode;
		}
		return Status(code, "Unknown Status Code");
	}
	
}

/**
 * HTTP status codes and their human-readable names.
 */
enum StatusCodes : Status {
	
	// informational
	continue_ = Status(100, "Continue"),
	switchingProtocols = Status(101, "Switching Protocols"),
	
	// successful
	ok = Status(200, "OK"),
	created = Status(201, "Created"),
	accepted = Status(202, "Accepted"),
	nonAuthoritativeContent = Status(203, "Non-Authoritative Information"),
	noContent = Status(204, "No Content"),
	resetContent = Status(205, "Reset Content"),
	partialContent = Status(206, "Partial Content"),
	
	// redirection
	multipleChoices = Status(300, "Multiple Choices"),
	movedPermanently = Status(301, "Moved Permanently"),
	found = Status(302, "Found"),
	seeOther = Status(303, "See Other"),
	notModified = Status(304, "Not Modified"),
	useProxy = Status(305, "Use Proxy"),
	switchProxy = Status(306, "Switch Proxy"),
	temporaryRedirect = Status(307, "Temporary Redirect"),
	permanentRedirect = Status(308, "Permanent Redirect"),
	
	// client error
	badRequest = Status(400, "Bad Request"),
	unauthorized = Status(401, "Unauthorized"),
	paymentRequired = Status(402, "Payment Required"),
	forbidden = Status(403, "Forbidden"),
	notFound = Status(404, "Not Found"),
	methodNotAllowed = Status(405, "Method Not Allowed"),
	notAcceptable = Status(406, "Not Acceptable"),
	proxyAuthenticationRequired = Status(407, "Proxy Authentication Required"),
	requestTimeout = Status(408, "Request Timeout"),
	conflict = Status(409, "Conflict"),
	gone = Status(410, "Gone"),
	lengthRequired = Status(411, "Length Required"),
	preconditionFailed = Status(412, "Precondition Failed"),
	payloadTooLarge = Status(413, "Payload Too Large"),
	uriTooLong = Status(414, "URI Too Long"),
	unsupportedMediaType = Status(415, "Unsupported Media Type"),
	rangeNotSatisfiable = Status(416, "Range Not Satisfiable"),
	expectationFailed = Status(417, "Expectation Failed"),
	
	// server error
	internalServerError = Status(500, "Internal Server Error"),
	notImplemented = Status(501, "Not Implemented"),
	badGateway = Status(502, "Bad Gateway"),
	serviceUnavailable = Status(503, "Service Unavailable"),
	gatewayTimeout = Status(504, "Gateway Timeout"),
	httpVersionNotSupported = Status(505, "HTTP Version Not Supported"),
	
}

/**
 * Frequently used Mime types.
 */
enum MimeTypes : string {
	
	// text
	html = "text/html",
	javascript = "text/javascript",
	css = "text/css",
	text = "text/plain",
	
	// images
	png = "image/png",
	jpeg = "image/jpeg",
	gif = "image/gif",
	ico = "image/x-icon",
	svg = "image/svg+xml",
	
	// other
	json = "application/json",
	zip = "application/zip",
	bin = "application/octet-stream",
	
}

private struct Headers {

	string[string] _headers, _lowerHeaders;

	string* opBinaryRight(string op : "in")(string key) pure @safe {
		return key.toLower in _lowerHeaders;
	}

	string opIndex(string key) pure @safe {
		return _lowerHeaders[key.toLower()];
	}

	string opIndexAssign(string value, string key) pure @safe {
		return _headers[key] = _lowerHeaders[key.toLower] = value;
	}

	string get(string key, lazy string defaultValue) pure @safe {
		return _lowerHeaders.get(key.toLower, defaultValue);
	}

	@property string[string] headers() {
		return _headers;
	}

}

private enum User {

	client,
	server

}

private enum Type {

	request,
	response

}

abstract class Http {

	protected string _method;

	public Status status;

	public Headers headers;

	protected string _body;

	/**
	 * Gets the method used for the request.
	 */
	public @property string method() pure nothrow @safe @nogc {
		return _method;
	}
	
	/**
	 * Gets the body of the request/response.
	 */
	public @property string body_() pure nothrow @safe @nogc {
		return _body;
	}
	
	/**
	 * Sets the body of the request/response.
	 */
	public @property string body_(T)(T data) {
		static if(is(T : string)) {
			return _body = cast(string)data;
		} else static if(is(T == JSONValue)) {
			this.contentType = MimeTypes.json;
			return _body = data.toString();
		} else static if(is(T == JSONValue[string]) || is(T == JSONValue[])) {
			return body_ = JSONValue(data);
		} else {
			return _body = data.to!string;
		}
	}
	
	/// ditto
	static if(__VERSION__ >= 2078) alias body = body_;
	
	/**
	 * Sets the response's content-type header.
	 * Example:
	 * ---
	 * response.contentType = MimeTypes.html;
	 * ---
	 */
	public @property string contentType(string contentType) pure @safe {
		return this.headers["Content-Type"] = contentType;
	}

	public abstract bool parse(string);

}

/**
 * Class for request and response.
 */
template HttpImpl(User user, Type type) {

	class HttpImpl : Http {

		static if(user == User.client && type == Type.response || user == User.server && type == Type.request) public NetworkAddress address;

		static if(type == Type.request) private URL _url;

		static if(type == Type.request) public @property URL url() pure nothrow @safe @nogc {
			return _url;
		}

		static if(user == User.server && type == Type.response) {
		
			/**
			 * Creates a 3xx redirect response and adds the `Location` field to
			 * the header.
			 * If not specified status code `301 Moved Permanently` will be used.
			 * Example:
			 * ---
			 * http.redirect("/index.html");
			 * http.redirect(302, "/view.php");
			 * http.redirect(StatusCodes.seeOther, "/icon.png");
			 * ---
			 */
			public void redirect(Status status, string location) {
				this.status = status;
				this.headers["Location"] = location;
				this.headers["Connection"] = "keep-alive";
			}
			
			/// ditto
			public void redirect(uint statusCode, string location) {
				this.redirect(Status.get(statusCode), location);
			}
			
			/// ditto
			public void redirect(string location) {
				this.redirect(StatusCodes.movedPermanently, location);
			}

		}

		public override string toString() {
			this.headers["Content-Length"] = to!string(this.body_.length);
			static if(type == Type.request) {
				return encodeHTTP(this.method.toUpper() ~ " " ~ encode(this.url.path ~ this.url.queryParams.toString()) ~ " HTTP/1.1", this.headers.headers, this.body_);
			} else {
				return encodeHTTP("HTTP/1.1 " ~ this.status.toString(), this.headers.headers, this.body_);
			}
		}

		public override bool parse(string data) {
			string status;
			static if(type == Type.request) {
				if(decodeHTTP(data, status, this.headers, this._body)) {
					string[] spl = status.split(" ");
					if(spl.length == 3) {
						_method = spl[0];
						_url.path = decode(spl[1]);
						return true;
					}
				}
			} else {
				if(decodeHTTP(data, status, this.headers, this._body)) {
					string[] head = status.split(" ");
					if(head.length >= 3) {
						try {
							this.status = Status(to!uint(head[1]), join(head[2..$], " "));
							return true;
						} catch(ConvException) {}
					}
				}
			}
			return false;
		}

	}

}

alias ClientRequest = HttpImpl!(User.client, Type.request);

alias ClientResponse = HttpImpl!(User.client, Type.response);

alias ServerRequest = HttpImpl!(User.server, Type.request);

alias ServerResponse = HttpImpl!(User.server, Type.response);

private enum crlf = "\r\n";

private string encodeHTTP(string status, string[string] headers, string content) {
	Appender!string ret;
	ret.put(status);
	ret.put(crlf);
	foreach(key, value; headers) {
		ret.put(key);
		ret.put(": ");
		ret.put(value);
		ret.put(crlf);
	}
	ret.put(crlf); // empty line
	ret.put(content);
	return ret.data;
}

private bool decodeHTTP(string str, ref string status, ref Headers headers, ref string content) {
	string[] spl = str.split(crlf);
	if(spl.length > 1) {
		status = spl[0];
		size_t index;
		while(++index < spl.length && spl[index].length) { // read until empty line
			auto s = spl[index].split(":");
			if(s.length >= 2) {
				headers[s[0].strip] = s[1..$].join(":").strip;
			} else {
				return false; // invalid header
			}
		}
		content = join(spl[index+1..$], crlf);
		return true;
	} else {
		return false;
	}
}
