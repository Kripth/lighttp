lighttp
<img align="right" alt="Logo" width="100" src="https://i.imgur.com/kWWtW6I.png">
=======

[![DUB Package](https://img.shields.io/dub/v/lighttp.svg)](https://code.dlang.org/packages/lighttp)
[![Build Status](https://travis-ci.org/Kripth/lighttp.svg?branch=master)](https://travis-ci.org/Kripth/lighttp)

Lighttp is a lightweight asynchronous HTTP and WebSocket server library for the D programming language with simple API.

```d
import std.file;

import lighttp;

void main(string[] args) {

	Server server = new Server();
	server.host("0.0.0.0");
	server.host("::");
	server.router.add(new Router());
	server.router.add("GET", "welcome", new Resource("text/html", read("welcome.html")));
	server.run();

}

class Router {

	// GET /
	@Get("") getIndex(Response response) {
		response.body = "Welcome to lighttp!";
	}
	
	// GET /image/uhDUnsj => imageId = "uhDUnsj"
	@Get("image", "([a-zA-Z0-9]{7})") getImage(Response response, string imageId) {
		if(exists("images/" ~ imageId)) {
			response.contentType = MimeTypes.jpeg;
			response.body = read("images/" ~ imageId);
		} else {
			response.status = StatusCodes.notFound;
		}
	}

}
```
