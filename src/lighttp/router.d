module lighttp.router;

import std.conv : to;
import std.regex : isRegexFor, matchAll;

import lighttp.util;

class Router {

	private Route[][string] routes;
	
	void handle(Request req, Response res) {
		if(req.path.length == 0 || "host" !in req.headers) {
			res.status = StatusCodes.badRequest;
		} else {
			auto routes = req.method in this.routes;
			if(routes) {
				foreach(route ; *routes) {
					if(route.handle(req, res)) return;
				}
			}
			res.status = StatusCodes.notFound;
		}
	}
	
	void error(Request req, Response res) {
		res.body_ = "<!DOCTYPE html><html><head><title>" ~ res.status.toString() ~ "</title><head><body><center><h1>" ~ res.status.toString() ~ "</h1></center><hr><center>" ~ res.headers.get("Server", "") ~ "</center></body></html>";
	}
	
	void register(T, E...)(RouteInfo!T info, void delegate(Request, Response, E) del) {
		this.routes[info.method] ~= new RouteOf!(T, E)(info.path, del);
	}

	void register(T)(RouteInfo!T info, Resource resource) {
		this.register(info, (Request req, Response res){ resource.apply(req, res); });
	}
	
}

class Route {

	abstract bool handle(Request req, Response res);

}

class RouteOf(T, E...) if(is(T == string) && E.length == 0 || isRegexFor!(T, string)) : Route {

	private T path;
	private void delegate(Request, Response, E) del;

	this(T path, void delegate(Request, Response, E) del) {
		this.path = path;
		this.del = del;
	}

	override bool handle(Request req, Response res) {
		static if(is(T == string)) {
			if(req.path == this.path) {
				this.del(req, res);
				return true;
			}
		} else {
			auto match = req.path.matchAll(this.path);
			if(match) {
				string[] matches;
				foreach(m ; match.front) matches ~= m;
				E args;
				static if(E.length == 1 && is(E[0] == string[])) {
					args[0] = matches[1..$];
				} else {
					assert(matches.length > args.length); //TODO do this check at compile time
					static foreach(i ; 0..E.length) {
						args[i] = to!(E[i])(matches[i+1]);
					}
				}
				this.del(req, res, args);
				return true;
			}
		}
		return false;
	}

}

struct RouteInfo(T) if(is(T == string) || isRegexFor!(T, string)) { 

	string method;
	T path;

}

auto CustomMethod(R)(string method, R path){ return RouteInfo!R(method, path); }

auto Get(R)(R path){ return RouteInfo!R("GET", path); }

auto Post(R)(R path){ return RouteInfo!R("POST", path); }

void registerRoutes(R:Router)(R router) {

	foreach(member ; __traits(allMembers, R)) {
		static if(__traits(getProtection, __traits(getMember, R, member)) == "public") {
			foreach(uda ; __traits(getAttributes, __traits(getMember, R, member))) {
				static if(isRouteInfo!(typeof(uda))) {
					static if(is(typeof(__traits(getMember, R, member)) == function)) {
						router.register(uda, mixin("&router." ~ member));
					} else {
						router.register(uda, mixin("router." ~ member));
					}
				}
			}
		}
	}
	
}

enum isRouteInfo(T) = is(T : RouteInfo!R, R);
