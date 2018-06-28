<img align="right" alt="Logo" width="100" src="https://i.imgur.com/kWWtW6I.png">

lighttp
=======

[![DUB Package](https://img.shields.io/dub/v/lighttp.svg)](https://code.dlang.org/packages/lighttp)
[![Build Status](https://travis-ci.org/Kripth/lighttp.svg?branch=master)](https://travis-ci.org/Kripth/lighttp)

Lighttp is a lightweight asynchronous HTTP and WebSocket server library for the D programming language with simple API.

```d
import lighttp;

void main(string[] args) {

	Server server = new Server();
	server.host("0.0.0.0");
	server.host("::");
	server.router.add(new Router());
	
	while(true) server.eventLoop.loop();

}

class Router {

	@Get("") getIndex(Response response) {
		response.body = "Welcome to lighttp!";
	}

}
```
