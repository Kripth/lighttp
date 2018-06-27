module lighttp.router;

import std.algorithm : max;
import std.base64 : Base64;
import std.conv : to, ConvException;
import std.digest.sha : sha1Of;
import std.regex : Regex, isRegexFor, regex, matchAll;
import std.string : startsWith, join;
import std.traits : Parameters, hasUDA;

import libasync : NetworkAddress, AsyncTCPConnection;

import lighttp.server : Connection, MultipartConnection, WebSocketConnection;
import lighttp.util;

struct HandleResult {

	bool success;
	Connection connection = null;

}

class Router {

	private Route[][string] routes;

	void handle(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res) {
		if(!req.path.startsWith("/")) {
			res.status = StatusCodes.badRequest;
		} else {
			auto routes = req.method in this.routes;
			if(routes) {
				foreach(route ; *routes) {
					route.handle(result, conn, req, res);
					if(result.success) return;
				}
			}
			res.status = StatusCodes.notFound;
		}
	}

	/**
	 * Handles a client or server error and displays an error
	 * page to the client.
	 */
	void error(Request req, Response res) {
		res.headers["Content-Type"] = "text/html";
		res.body_ = "<!DOCTYPE html><html><head><title>" ~ res.status.message ~ "</title></head><body><center><h1>" ~ res.status.toString() ~ "</h1></center><hr><center>lighttp/0.1</center></body></html>";
	}

	/**
	 * Adds a route.
	 */
	void add(T, E...)(RouteInfo!T info, void delegate(E) del) {
		this.routes[info.method] ~= new RouteOf!(T, E)(info.path, del);
	}

	void add(T)(RouteInfo!T info, Resource resource) {
		this.add(info, (Request req, Response res){ resource.apply(req, res); });
	}

	void add(T, E...)(string method, T path, void delegate(E) del) {
		this.add(RouteInfo!T(method, path), del);
	}

	void add(T)(string method, T path, Resource resource) {
		this.add(RouteInfo!T(method, path), resource);
	}
	
	void addMultipart(T, E...)(RouteInfo!T info, void delegate(E) del) {
		this.routes[info.method] ~= new MultipartRouteOf!(T, E)(info.path, del);
	}

	void addWebSocket(W:WebSocketConnection, T)(RouteInfo!T info, W delegate() del) {
		static if(__traits(hasMember, W, "onConnect")) this.routes[info.method] ~= new WebSocketRouteOf!(W, T, Parameters!(W.onConnect))(info.path, del);
		else this.routes[info.method] ~= new WebSocketRouteOf!(W, T)(info.path, del);
	}

	void addWebSocket(W:WebSocketConnection, T)(RouteInfo!T info) if(!__traits(isNested, W)) {
		this.addWebSocket!(W, T)(info, { return new W(); });
	}

	void remove(T, E...)(RouteInfo!T info, void delegate(E) del) {
		//TODO
	}
	
}

class Route {

	abstract void handle(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res);

}

class RouteImpl(T, E...) if(is(T == string) || isRegexFor!(T, string)) : Route {

	private T path;
	
	static if(E.length) {
		static if(is(E[0] == NetworkAddress)) {
			enum __address = 0;
			static if(E.length > 1) {
				static if(is(E[1] == Request)) {
					enum __request = 1;
					static if(E.length > 2 && is(E[2] == Response)) {
						enum __response = 2;
					}
				} else static if(is(E[1] == Response)) {
					enum __response = 1;
				}
			}
		} else static if(is(E[0] == Request)) {
			enum __request = 0;
			static if(E.length > 1 && is(E[1] == Response)) enum __response = 1;
		} else static if(is(E[0] == Response)) {
			enum __response = 0;
		}
	}
	
	static if(!is(typeof(__address))) enum __address = -1;
	static if(!is(typeof(__request))) enum __request = -1;
	static if(!is(typeof(__response))) enum __response = -1;
	
	static if(__address == -1 && __request == -1 && __response == -1) {
		alias Args = E[0..0];
		alias Match = E[0..$];
	} else {
		enum _ = max(__address, __request, __response) + 1;
		alias Args = E[0.._];
		alias Match = E[_..$];
	}

	static assert(Match.length == 0 || !is(T : string));
	
	this(T path) {
		this.path = path;
	}
	
	void callImpl(void delegate(E) del, AsyncTCPConnection conn, Request req, Response res, Match match) {
		Args args;
		static if(__address != -1) args[__address] = conn.local;
		static if(__request != -1) args[__request] = req;
		static if(__response != -1) args[__response] = res;
		del(args, match);
	}
	
	abstract void call(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res, Match match);
	
	override void handle(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res) {
		static if(is(T == string)) {
			if(req.path[1..$] == this.path) {
				this.call(result, conn, req, res);
				result.success = true;
			}
		} else {
			auto match = req.path[1..$].matchAll(this.path);
			if(match && match.post.length == 0) {
				string[] matches;
				foreach(m ; match.front) matches ~= m;
				Match args;
				static if(E.length == 1 && is(E[0] == string[])) {
					args[0] = matches[1..$];
				} else {
					if(matches.length != args.length + 1) throw new Exception("Arguments count mismatch"); //TODO do this check at compile time if possible
					static foreach(i ; 0..Match.length) {
						args[i] = to!(Match[i])(matches[i+1]);
					}
				}
				this.call(result, conn, req, res, args);
				result.success = true;
			}
		}
	}
	
}

class RouteOf(T, E...) : RouteImpl!(T, E) {

	private void delegate(E) del;
	
	this(T path, void delegate(E) del) {
		super(path);
		this.del = del;
	}
	
	override void call(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res, Match match) {
		this.callImpl(this.del, conn, req, res, match);
	}
	
}

class MultipartRouteOf(T, E...) : RouteOf!(T, E) {

	this(T path, void delegate(E) del) {
		super(path, del);
	}

	override void call(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res, Match match) {
		auto lstr = "content-length" in req.headers;
		if(lstr) {
			try {
				size_t length = to!size_t(*lstr);
				if(req.body_.length >= length) {
					return super.call(result, conn, req, res, match);
				} else {
					// wait for full data
					result.connection = new MultipartConnection(conn, length, req, { super.call(result, conn, req, res, match); });
					return;
				}
			} catch(ConvException) {}
		}
		result.success = false;
		res.status = StatusCodes.badRequest;
	}

}

class WebSocketRouteOf(WebSocket, T, E...) : RouteImpl!(T, E) {

	private WebSocket delegate() createWebSocket;

	this(T path, WebSocket delegate() createWebSocket) {
		super(path);
		this.createWebSocket = createWebSocket;
	}

	override void call(ref HandleResult result, AsyncTCPConnection conn, Request req, Response res, Match match) {
		auto key = "sec-websocket-key" in req.headers;
		if(key) {
			res.status = StatusCodes.switchingProtocols;
			res.headers["Sec-WebSocket-Accept"] = Base64.encode(sha1Of(*key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).idup;
			res.headers["Connection"] = "upgrade";
			res.headers["Upgrade"] = "websocket";
			// create web socket and set callback for onConnect
			WebSocket webSocket = this.createWebSocket();
			webSocket.conn = conn;
			result.connection = webSocket;
			static if(__traits(hasMember, WebSocket, "onConnect")) webSocket.onStartImpl = { this.callImpl(&webSocket.onConnect, conn, req, res, match); };
		} else {
			res.status = StatusCodes.notFound;
		}
	}

}

struct RouteInfo(T) if(is(T : string) || is(T == Regex!char) || isRegexFor!(T, string)) {
	
	string method;
	T path;

}

auto routeInfo(E...)(string method, E path) {
	static if(E.length == 0) {
		return routeInfo(method, "");
	} else static if(E.length == 1) {
		static if(isRegexFor!(E[0], string)) return RouteInfo!E(method, path);
		else return RouteInfo!(Regex!char)(method, regex(path));
	} else {
		string[] p;
		foreach(pp ; path) p ~= pp;
		return RouteInfo!(Regex!char)(method, regex(p.join(`\/`)));
	}
}

private enum isRouteInfo(T) = is(T : RouteInfo!R, R);

auto CustomMethod(R)(string method, R path){ return RouteInfo!R(method, path); }

auto Get(R...)(R path){ return routeInfo!R("GET", path); }

auto Post(R...)(R path){ return routeInfo!R("POST", path); }

enum Multipart;

void registerRoutes(R:Router)(R router) {

	foreach(member ; __traits(allMembers, R)) {
		static if(__traits(getProtection, __traits(getMember, R, member)) == "public") {
			foreach(uda ; __traits(getAttributes, __traits(getMember, R, member))) {
				static if(is(typeof(uda)) && isRouteInfo!(typeof(uda))) {
					mixin("alias M = router." ~ member ~ ";");
					static if(is(typeof(__traits(getMember, R, member)) == function)) {
						// function
						static if(hasUDA!(__traits(getMember, R, member), Multipart)) router.addMultipart(uda, mixin("&router." ~ member));
						else router.add(uda, mixin("&router." ~ member));
					} else static if(is(M == class)) {
						// websocket
						static if(__traits(isNested, M)) router.addWebSocket!M(uda, { return router.new M(); });
						else router.addWebSocket!M(uda);
					} else {
						// member
						router.add(uda, mixin("router." ~ member));
					}
				}
			}
		}
	}
	
}
