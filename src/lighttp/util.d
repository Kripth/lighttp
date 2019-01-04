module lighttp.util;

import std.array : Appender;
import std.conv : to, ConvException;
import std.datetime : DateTime;
import std.json : JSONValue;
import std.regex : ctRegex;
import std.string : toUpper, toLower, split, join, strip, indexOf;
import std.traits : EnumMembers;
import std.uri : encode, decodeComponent;

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
 * Frequently used mime types.
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

struct Cookie {

	string name;
	string value;
	DateTime expires;
	size_t maxAge;
	string domain;
	string path;
	bool secure;
	bool httpOnly;

	string toString() {
		Appender!string ret;
		ret.put(name);
		ret.put("=");
		ret.put(value);
		if(expires != DateTime.init) {
			ret.put(";Expires=");
			ret.put(expires.toString()); //TODO format correctly
		}
		if(maxAge != size_t.init) {
			ret.put(";Max-Age=");
			ret.put(maxAge.to!string);
		}
		if(domain.length) {
			ret.put(";Domain=");
			ret.put(domain);
		}
		if(path.length) {
			ret.put(";Path=");
			ret.put(path);
		}
		if(secure) ret.put(";Secure");
		if(httpOnly) ret.put(";HttpOnly");
		return ret.data;
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

/**
 * Base class for requests and responses.
 */
abstract class Http {

	/**
	 * Headers utility.
	 */
	static struct Headers {
		
		static struct Header {
			
			string key;
			string value;
			
		}
		
		private Header[] _headers;
		size_t[string] _headersIndexes;

		/**
		 * Gets the pointer to a header.
		 * The key is case insensitive.
		 * Example:
		 * ---
		 * headers["Connection"] = "keep-alive";
		 * assert(("connection" in headers) is ("Connection" in headers));
		 * ---
		 */
		string* opBinaryRight(string op : "in")(string key) pure @safe {
			if(auto ptr = key.toLower in _headersIndexes) return &_headers[*ptr].value;
			else return null;
		}

		/**
		 * Gets the value of a header.
		 * The key is case insensitive.
		 * Example:
		 * ---
		 * headers["Connection"] = "keep-alive";
		 * assert(header["connection"] == "keep-alive");
		 * ---
		 */
		string opIndex(string key) pure @safe {
			return _headers[_headersIndexes[key.toLower]].value;
		}
		
		/**
		 * Gets the value of a header and returns `defaultValue` if
		 * it does not exist.
		 * Example:
		 * ---
		 * assert(headers.get("Connection", "close") == "close");
		 * headers["Connection"] = "keep-alive";
		 * assert(headers.get("Connection", "close") != "close");
		 * ---
		 */
		string get(string key, lazy string defaultValue) pure @safe {
			if(auto ptr = key.toLower in _headersIndexes) return _headers[*ptr].value;
			else return defaultValue;
		}

		/**
		 * Assigns, and overrides if it already exists, a header value.
		 * The key is case-insensitive.
		 * Example:
		 * ---
		 * headers["Connection"] = "keep-alive";
		 * headers["connection"] = "close";
		 * assert(headers["Connection"] == "close");
		 * --
		 */
		string opIndexAssign(string value, string key) pure @safe {
			if(auto ptr = key.toLower in _headersIndexes) return _headers[*ptr].value = value;
			else {
				_headersIndexes[key.toLower] = _headers.length;
				_headers ~= Header(key, value);
				return value;
			}
		}

		/**
		 * Adds a new key-value pair to the headers without overriding
		 * the existing ones.
		 * Example:
		 * ---
		 * headers.add("Set-Cookie", "a=b");
		 * headers.add("Set-Cookie", "b=c");
		 * ---
		 */
		void add(string key, string value) pure @safe {
			if(!(key.toLower in _headersIndexes)) _headersIndexes[key.toLower] = _headers.length;
			_headers ~= Header(key, value);
		}
		
		@property Header[] headers() {
			return _headers;
		}
		
	}

	protected string _method;

	/**
	 * Gets and sets the status of the request/response.
	 * The value can be one of the enum `StatusCodes` or a custom
	 * status using the `Status` struct.
	 */
	public Status status;

	/**
	 * Gets the header manager of the request/response.
	 * The available methods are the same of the associative array's
	 * except that keys are case-insensitive.
	 * Example:
	 * ---
	 * headers["Connection"] = "keep-alive";
	 * assert(headers["connection"] == "keep-alive");
	 * ---
	 */
	public Headers headers;

	private bool _cookiesInit = false;
	private string[string] _cookies;

	protected string _body;

	/**
	 * Gets the method used for the request.
	 */
	public @property string method() pure nothrow @safe @nogc {
		return _method;
	}

	/**
	 * Gets the cookies sent in the `Cookie` header in the request.
	 * This property is lazily initialized.
	 */
	public @property string[string] cookies() {
		if(!_cookiesInit) {
			if(auto cookies = "cookie" in headers) {
				foreach(cookie ; split(*cookies, ";")) {
					cookie = cookie.strip;
					immutable eq = cookie.indexOf("=");
					if(eq > 0) {
						_cookies[cookie[0..eq]] = cookie[eq+1..$];
					}
				}
			}
			_cookiesInit = true;
		}
		return _cookies;
	}

	/**
	 * Adds a cookie to the response's header.
	 */
	public void add(Cookie cookie) {
		this.headers.add("Set-Cookie", cookie.toString());
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

		static if(user == User.server && type == Type.response) public bool ready = true;

		/**
		 * Gets the url of the request. `url.path` can be used to
		 * retrive the path and `url.queryParams` to retrive the query
		 * parameters.
		 */
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
						immutable q = spl[1].indexOf("?");
						if(q >= 0) {
							_url.path = decodeComponent(spl[1][0..q]);
							foreach(param ; spl[1][q+1..$].split("&")) {
								immutable eq = param.indexOf("=");
								if(eq >= 0) {
									_url.queryParams.add(decodeComponent(param[0..eq]), decodeComponent(param[eq+1..$]));
								} else {
									_url.queryParams.add(decodeComponent(param), "");
								}
							}
						} else {
							_url.path = decodeComponent(spl[1]);
						}
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

private string encodeHTTP(string status, Http.Headers.Header[] headers, string content) {
	Appender!string ret;
	ret.put(status);
	ret.put(crlf);
	foreach(header ; headers) {
		ret.put(header.key);
		ret.put(": ");
		ret.put(header.value);
		ret.put(crlf);
	}
	ret.put(crlf); // empty line
	ret.put(content);
	return ret.data;
}

private bool decodeHTTP(string str, ref string status, ref Http.Headers headers, ref string content) {
	string[] spl = str.split(crlf);
	if(spl.length > 1) {
		status = spl[0];
		size_t index;
		while(++index < spl.length && spl[index].length) { // read until empty line
			auto s = spl[index].split(":");
			if(s.length >= 2) {
				headers.add(s[0].strip, s[1..$].join(":").strip);
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
