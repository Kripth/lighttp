module app;

import std.algorithm : sort;
import std.array : Appender;
import std.file;
import std.getopt : getopt;
import std.path : buildNormalizedPath;
import std.regex : ctRegex;
import std.string : startsWith, endsWith, toLower;

import lighttp;

void main(string[] args) {

	string path = ".";
	string ip = "0.0.0.0";
	ushort port = 80;
	
	getopt(args, "path", &path, "ip", &ip, "port", &port);

	auto server = new Server();
	server.host(ip, port);
	server.router.add(new StaticRouter(path));
	server.run();

}

class StaticRouter {

	private immutable string path;
	
	this(string path) {
		if(!path.endsWith("/")) path ~= "/";
		this.path = path;
	}

	@Get(`(.*)`) get(ServerRequest req, ServerResponse res, string _file) {
		//TODO remove ../ for security reason
		immutable file = buildNormalizedPath(this.path, _file);
		if(exists(file)) {
			if(file.isFile) {
				// browsers should be able to get the mime type from the content
				res.body_ = read(file);
			} else if(file.isDir) {
				string[] dirs, files;
				foreach(f ; dirEntries(file, SpanMode.shallow)) {
					if(f.isDir) dirs ~= f[file.length+1..$];
					else if(f.isFile) files ~= f[file.length+1..$];
				}
				sort!((a, b) => a.toLower < b.toLower)(dirs);
				sort!((a, b) => a.toLower < b.toLower)(files);
				if(!_file.startsWith("/")) _file = "/" ~ _file;
				if(!_file.endsWith("/")) _file ~= "/";
				Appender!string ret;
				ret.put("<h1>Index of ");
				ret.put(_file);
				ret.put("</h1><hr>");
				foreach(dir ; dirs) ret.put("<a href='" ~ _file ~ dir ~ "'>" ~ dir ~ "/</a><br>");
				foreach(f ; files) ret.put("<a href='" ~ _file ~ f ~ "'>" ~ f ~ "</a><br>");
				res.body_ = ret.data;
				res.headers["Content-Type"] = "text/html";
			}
		} else {
			res.status = StatusCodes.notFound;
		}
	}

}
