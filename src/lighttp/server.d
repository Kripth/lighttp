module lighttp.server;

import std.system : Endian;

import libasync;

import xbuffer;

import lighttp.router;
import lighttp.util;

private enum __lighttp = "lighttp/0.1.0";

class Server {

	private EventLoop evl;
	private Router router;

	private immutable string name;

	this(R:Router)(EventLoop evl, R router, string name=__lighttp) {
		this.evl = evl;
		registerRoutes(router);
		this.router = router;
		this.name = name;
	}

	this(R:Router)(R router, string name=__lighttp) {
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
				auto req = new Typed!(immutable char)(16);
				static ubyte[] buffer = new ubyte[1024];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) req.write(buffer[0..len]);
					if(len < buffer.length) break;
				}
				import std.stdio : writeln;
				writeln(req.data);
				Request request = new Request();
				Response response = new Response();
				response.headers["Server"] = name;
				HandleResult result;
				if(request.parse(req.data)) {
					try router.handle(result, this.conn, request, response);
					catch(Exception) response.status = StatusCodes.internalServerError;
				} else {
					response.status = StatusCodes.badRequest;
				}
				if(response.status.code >= 400) router.error(request, response);
				this.conn.send(cast(ubyte[])response.toString());
				if(result.webSocket is null) {
					this.conn.kill();
				} else {
					_handler = &result.webSocket.handle;
					result.callOnConnect();
				}
			}
		}

	}

}

/**
 * Base class for web socket clients.
 */
class WebSocketClient {

	AsyncTCPConnection conn; // set by the router

	private Typed!ubyte buffer;

	this() {
		this.buffer = new Typed!ubyte(1024);
	}

	final void handle(TCPEvent event) {
		switch(event) with(TCPEvent) {
			case READ:
				this.buffer.reset();
				static ubyte[] buffer = new ubyte[1024];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) this.buffer.write(buffer[0..len]);
					if(len < buffer.length) break;
				}
				try if((this.buffer.get() & 0b1111) == 1) {
					immutable info = this.buffer.get();
					immutable masked = (info & 0b10000000) != 0;
					size_t length = info & 0b01111111;
					if(length == 0b01111110) {
						length = this.buffer.read!(Endian.bigEndian, ushort)();
					} else if(length == 0b01111111) {
						length = this.buffer.read!(Endian.bigEndian, ulong)() & size_t.max;
					}
					if(masked) {
						ubyte[] mask = this.buffer.get(4);
						ubyte[] data = this.buffer.get(length);
						foreach(i, ref ubyte p; data) {
							p ^= mask[i % 4];
						}
						this.onReceive(data);
					} else {
						this.onReceive(this.buffer.get(length));
					}
				} catch(BufferOverflowException) {}
				break;
			case CLOSE:
				this.onClose();
				break;
			default:
				break;
		}
	}
	
	/**
	 * Sends data to the connected web socket.
	 */
	void send(in void[] data) {
		this.buffer.reset();
		this.buffer.put(0b10000001);
		if(data.length < 0b01111110) {
			this.buffer.put(data.length & ubyte.max);
		} else if(data.length < ushort.max) {
			this.buffer.put(0b01111110);
			this.buffer.write!(Endian.bigEndian, ushort)(data.length & ushort.max);
		} else {
			this.buffer.put(0b01111111);
			this.buffer.write!(Endian.bigEndian, ulong)(data.length);
		}
		this.buffer.write(data);
		this.conn.send(this.buffer.data);
	}

	/**
	 * Notifies that the client has sent some data.
	 */
	abstract void onReceive(ubyte[] data);

	/**
	 * Notifies that the connection has been interrupted.
	 */
	abstract void onClose();

}
