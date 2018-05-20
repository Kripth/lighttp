module lighttp.util;

import std.array : Appender;
import std.conv : to, ConvException;
import std.base64 : Base64URLNoPadding;
import std.digest.crc : crc32Of;
import std.json : JSONValue;
import std.string : toUpper, toLower, split, join, strip, indexOf;
import std.traits : EnumMembers;
import std.uri : encode, decode;
import std.zlib : HeaderFormat, Compress;

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
	
	// success
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
	
	// client errors
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
	unsupportedMediaType = Status(415, "UnsupportedMediaType"),
	rangeNotSatisfiable = Status(416, "Range Not Satisfiable"),
	expectationFailed = Status(417, "Expectation Failed"),
	
	// server errors
	internalServerError = Status(500, "Internal Server Error"),
	notImplemented = Status(501, "Not Implemented"),
	badGateway = Status(502, "Bad Gateway"),
	serviceUnavailable = Status(503, "Service Unavailable"),
	gatewayTimeout = Status(504, "Gateway Timeout"),
	httpVersionNotSupported = Status(505, "HTTP Version Not Supported"),
	
}

abstract class HTTP {

	enum VERSION = "HTTP/1.1";
	
	enum GET = "GET";
	enum POST = "POST";

	/**
	 * Method used.
	 */
	string method;

	/**
	 * Headers of the request/response.
	 */
	string[string] headers;

	protected string _body;

	@property string body_() pure nothrow @safe @nogc {
		return _body;
	}

	/*@property string body_(in void[] data) pure nothrow @nogc {
		return _body = cast(string)data;
	}*/

	@property string body_(T)(T data) {
		static if(is(T : string)) {
			return _body = cast(string)data;
		} else static if(is(T == JSONValue)) {
			this.headers["Content-Type"] = "application/json; charset=utf-8";
			return _body = data.toString();
		} else static if(is(T == JSONValue[string]) || is(T == JSONValue[])) {
			return body_ = JSONValue(data);
		} else {
			return _body = data.to!string;
		}
	}

	static if(__VERSION__ >= 2078) alias body = body_;

}

enum defaultHeaders = (string[string]).init;

/**
 * Container for a HTTP request.
 * Example:
 * ---
 * new Request("GET", "/");
 * new Request(Request.POST, "/subscribe.php");
 * ---
 */
class Request : HTTP {
	
	/**
	 * Path of the request. It should start with a slash.
	 */
	string path;

	public this() {}
	
	public this(string method, string path, string[string] headers=defaultHeaders) {
		this.method = method;
		this.path = path;
		this.headers = headers;
	}
	
	/**
	 * Creates a get request.
	 * Example:
	 * ---
	 * auto get = Request.get("/index.html", ["Host": "127.0.0.1"]);
	 * assert(get.toString() == "GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\n");
	 * ---
	 */
	public static Request get(string path, string[string] headers=defaultHeaders) {
		return new Request(GET, path, headers);
	}
	
	/**
	 * Creates a post request.
	 * Example:
	 * ---
	 * auto post = Request.post("/sub.php", ["Connection": "Keep-Alive"], "name=Mark&surname=White");
	 * assert(post.toString() == "POST /sub.php HTTP/1.1\r\nConnection: Keep-Alive\r\n\r\nname=Mark&surname=White");
	 * ---
	 */
	public static Request post(string path, string[string] headers=defaultHeaders, string body_="") {
		Request request = new Request(POST, path, headers);
		request.body_ = body_;
		return request;
	}
	
	/// ditto
	public static Request post(string path, string data, string[string] headers=defaultHeaders) {
		return post(path, headers, data);
	}
	
	/**
	 * Encodes the request into a string.
	 * Example:
	 * ---
	 * auto request = new Request(Request.GET, "index.html", ["Connection": "Keep-Alive"]);
	 * assert(request.toString() == "GET /index.html HTTP/1.1\r\nConnection: Keep-Alive\r\n");
	 * ---
	 */
	public override string toString() {
		if(this.body_.length) this.headers["Content-Length"] = to!string(this.body_.length);
		return encodeHTTP(this.method.toUpper() ~ " " ~ encode(this.path) ~ " HTTP/1.1", this.headers, this.body_);
	}
	
	/**
	 * Parses a string and returns a Request.
	 * If the request is successfully parsed Request.valid will be true.
	 * Please note that every key in the header is converted to lowercase for
	 * an easier search in the associative array.
	 * Example:
	 * ---
	 * auto request = Request.parse("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Keep-Alive\r\n");
	 * assert(request.valid);
	 * assert(request.method == Request.GET);
	 * assert(request.headers["Host"] == "127.0.0.1");
	 * assert(request.headers["Connection"] == "Keep-Alive");
	 * ---
	 */
	public bool parse(string data) {
		string status;
		if(decodeHTTP(data, status, this.headers, this._body)) {
			string[] spl = status.split(" ");
			if(spl.length == 3) {
				this.method = spl[0];
				this.path = decode(spl[1]);
				return true;
			}
		}
		return false;
	}
	
}

/**
 * Container for an HTTP response.
 * Example:
 * ---
 * new Response(200, ["Connection": "Close"], "<b>Hi there</b>");
 * new Response(404, [], "Cannot find the specified path");
 * new Response(204);
 * ---
 */
class Response : HTTP {
	
	/**
	 * Status of the response.
	 */
	Status status;
	
	/**
	 * If the response was parsed, indicates whether it was in a
	 * valid HTTP format.
	 */
	bool valid;

	public this() {}
	
	public this(Status status, string[string] headers=defaultHeaders, string body_="") {
		this.status = status;
		this.headers = headers;
		this.body_ = body_;
	}
	
	public this(uint statusCode, string[string] headers=defaultHeaders, string body_="") {
		this(Status.get(statusCode), headers, body_);
	}
	
	public this(Status status, string body_) {
		this(status, defaultHeaders, body_);
	}
	
	public this(uint statusCode, string body_) {
		this(statusCode, defaultHeaders, body_);
	}
	
	/**
	 * Creates a response for an HTTP error an automatically generates
	 * an HTML page to display it.
	 * Example:
	 * ---
	 * Response.error(404);
	 * Response.error(StatusCodes.methodNotAllowed, ["Allow": "GET"]);
	 * ---
	 */
	public static Response error(Status status, string[string] headers=defaultHeaders) {
		immutable message = status.toString();
		headers["Content-Type"] = "text/html";
		return new Response(status, headers, "<!DOCTYPE html><html><head><title>" ~ message ~ "</title></head><body><center><h1>" ~ message ~ "</h1></center><hr><center>" ~ headers.get("Server", "sel-net") ~ "</center></body></html>");
	}
	
	/// ditto
	public static Response error(uint statusCode, string[string] headers=defaultHeaders) {
		return error(Status.get(statusCode), headers);
	}
	
	/**
	 * Creates a 3xx redirect response and adds the `Location` field to
	 * the header.
	 * If not specified status code `301 Moved Permanently` will be used.
	 * Example:
	 * ---
	 * Response.redirect("/index.html");
	 * Response.redirect(302, "/view.php");
	 * Response.redirect(StatusCodes.seeOther, "/icon.png", ["Server": "sel-net"]);
	 * ---
	 */
	public void redirect(Status status, string location) {
		this.status = status;
		this.headers["Location"] = location;
	}
	
	/// ditto
	public void redirect(uint statusCode, string location) {
		this.redirect(Status.get(statusCode), location);
	}
	
	/// ditto
	public void redirect(string location) {
		this.redirect(StatusCodes.movedPermanently, location);
	}
	
	/**
	 * Encodes the response into a string.
	 * The `Content-Length` header field is created automatically
	 * based on the length of the content field.
	 * Example:
	 * ---
	 * auto response = new Response(200, [], "Hi");
	 * assert(response.toString() == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nHi");
	 * ---
	 */
	public override string toString() {
		this.headers["Content-Length"] = to!string(this.body_.length);
		return encodeHTTP("HTTP/1.1 " ~ this.status.toString(), this.headers, this.body_);
	}
	
	/**
	 * Parses a string and returns a Response.
	 * If the response is successfully parsed Response.valid will be true.
	 * Please note that every key in the header is converted to lowercase for
	 * an easier search in the associative array.
	 * Example:
	 * ---
	 * auto response = new Response()
	 * assert(response.parse("HTTP/1.1 200 OK\r\nContent-Type: plain/text\r\nContent-Length: 4\r\n\r\ntest"));
	 * assert(response.status == 200);
	 * assert(response.headers["content-type"] == "text/plain");
	 * assert(response.headers["content-length"] == "4");
	 * assert(response.content == "test");
	 * ---
	 */
	public bool parse(string str) {
		string status;
		if(decodeHTTP(str, status, this.headers, this._body)) {
			string[] head = status.split(" ");
			if(head.length >= 3) {
				try {
					this.status = Status(to!uint(head[1]), join(head[2..$], " "));
					return true;
				} catch(ConvException) {}
			}
		}
		return false;
	}
	
}

private enum CR_LF = "\r\n";

private string encodeHTTP(string status, string[string] headers, string content) {
	Appender!string ret;
	ret.put(status);
	ret.put(CR_LF);
	foreach(key, value; headers) {
		ret.put(key);
		ret.put(": ");
		ret.put(value);
		ret.put(CR_LF);
	}
	ret.put(CR_LF); // empty line
	ret.put(content);
	return ret.data;
}

private bool decodeHTTP(string str, ref string status, ref string[string] headers, ref string content) {
	string[] spl = str.split(CR_LF);
	if(spl.length > 1) {
		status = spl[0];
		size_t index;
		while(++index < spl.length && spl[index].length) { // read until empty line
			auto s = spl[index].split(":");
			if(s.length >= 2) {
				headers[s[0].strip.toLower()] = s[1..$].join(":").strip;
			} else {
				return false; // invalid header
			}
		}
		content = join(spl[index+1..$], "\r\n");
		return true;
	} else {
		return false;
	}
}

class Resource {

	private immutable string mime;

	public immutable size_t thresold;
	
	public const(void)[] uncompressed;
	public const(void)[] compressed = null;

	public this(string mime, size_t thresold=512) {
		this.mime = mime;
		this.thresold = thresold;
	}

	public this(string mime, in void[] data) {
		this(mime);
		this.data = data;
	}

	public @property const(void)[] data(in void[] data) {
		this.uncompressed = data;
		if(data.length >= this.thresold) this.compress();
		else this.compressed = null;
		return this.uncompressed;
	}
	
	private void compress() {
		Compress compress = new Compress(6, HeaderFormat.gzip);
		auto data = compress.compress(this.uncompressed);
		data ~= compress.flush();
		this.compressed = data;
	}

	public void apply(Request req, Response res) {
		if(this.compressed !is null && req.headers.get("accept-encoding", "").indexOf("gzip") != -1) {
			res.headers["Content-Encoding"] = "gzip";
			res.body_ = cast(string)this.compressed;
		} else {
			res.body_ = cast(string)this.uncompressed;
		}
		res.headers["Content-Type"] = this.mime;
	}
	
}

class CachedResource : Resource {

	private string etag;

	public this(string mime, size_t thresold=512) {
		super(mime, thresold);
	}
	
	public this(string mime, in void[] data) {
		super(mime, data);
	}

	public override @property const(void)[] data(in void[] data) {
		this.etag = Base64URLNoPadding.encode(crc32Of(data));
		return super.data(data);
	}

	public override void apply(Request req, Response res) {
		if(req.headers.get("if-none-match", "") == this.etag) {
			res.status = StatusCodes.notModified;
		} else {
			super.apply(req, res);
			res.headers["Cache-Control"] = "public, max-age=31536000";
			res.headers["ETag"] = this.etag;
		}
	}

}
