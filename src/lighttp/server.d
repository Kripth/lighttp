module lighttp.server;

import libasync;
import memutils.all;

import lighttp.router;
import lighttp.util;

class Server {

	private EventLoop evl;
	private Router router;

	private immutable string name;

	this(R:Router)(EventLoop evl, R router, string name="lighttp") {
		this.evl = evl;
		registerRoutes(router);
		this.router = router;
		this.name = name;
	}

	this(R:Router)(R router, string name="lighttp") {
		this(getThreadEventLoop(), router, name);
	}

	@property EventLoop eventLoop() pure nothrow @safe @nogc {
		return this.evl;
	}

	void host(string ip, ushort port) {
		auto listener = new AsyncTCPListener(this.evl);
		listener.host(ip, port);
		listener.run(&this.handler);
	}

	void delegate(TCPEvent) handler(AsyncTCPConnection conn) {
		auto ret = new Connection(conn);
		return &ret.handle;
	}

	class Connection {

		AsyncTCPConnection conn;

		private void delegate(TCPEvent) _handler;

		this(AsyncTCPConnection conn) {
			this.conn = conn;
			_handler = &handleHTTP;
		}

		void handle(TCPEvent event) {
			_handler(event);
		}

		void handleHTTP(TCPEvent event) {
			if(event == TCPEvent.READ) {
				string req;
				static ubyte[] buffer = new ubyte[4096];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) req ~= cast(string)buffer[0..len];
					if(len < buffer.length) break;
				}
				Request request = ThreadMem.alloc!Request();
				Response response = ThreadMem.alloc!Response();
				response.headers["Server"] = name;
				if(request.parse(req)) {
					try router.handle(request, response);
					catch(Exception) response.status = StatusCodes.internalServerError;
				} else {
					response.status = StatusCodes.badRequest;
				}
				if(response.status.code >= 400) router.error(request, response);
				this.conn.send(cast(ubyte[])response.toString());
				this.conn.kill();
				ThreadMem.free(request);
				ThreadMem.free(response);
			}
		}

		void handleWebSocket(TCPEvent event) {

		}

	}

}
