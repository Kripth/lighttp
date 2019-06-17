import std.file;
import std.stdio;

import lighttp;

void main(string[] args) {
	auto server = new Server();
	
	server.host("0.0.0.0");
	server.host("::");
	
	server.router.add(new Router());
	server.run();
}

class Router {
	@Get("") getDownload(ServerRequest req, ServerResponse res) {
		res.headers["Content-Type"] = "text/html";
		res.headers["Content-Disposition"] = "attachment; filename=\"test.html\"";

		res.body = "<HTML>Save me!</HTML>";
	}
}
