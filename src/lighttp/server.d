module lighttp.server;

import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.conv : to;

import libasync;
import memutils.all;

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
				string req;
				static ubyte[] buffer = new ubyte[1024];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) req ~= cast(string)buffer[0..len];
					if(len < buffer.length) break;
				}
				Request request = new Request();
				Response response = new Response();
				response.headers["Server"] = name;
				HandleResult result;
				if(request.parse(req)) {
					try router.handle(result, this.conn, request, response);
					catch(Exception) response.status = StatusCodes.internalServerError;
				} else {
					response.status = StatusCodes.badRequest;
				}
				if(response.status.code >= 400) router.error(request, response);
				this.conn.send(cast(ubyte[])response.toString());
				if(result.webSocket is null) this.conn.kill();
				else {
					_handler = &result.webSocket.handle;
					result.callOnConnect();
				}
			}
		}

	}

}

class WebSocketClient {

	AsyncTCPConnection conn; // set by the router

	final void handle(TCPEvent event) {
		switch(event) with(TCPEvent) {
			case READ:
				ubyte[] payload;
				static ubyte[] buffer = new ubyte[1024];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) payload ~= buffer[0..len];
					if(len < buffer.length) break;
				}
				if(payload.length > 2 && (payload[0] & 0b1111) == 1) {
					bool masked = (payload[1] & 0b10000000) != 0;
					size_t length = payload[1] & 0b01111111;
					size_t index = 2;
					if(length == 0b01111110) {
						if(payload.length >= index + 2) {
							ubyte[2] bytes = payload[index..index+2];
							length = bigEndianToNative!ushort(bytes);
							index += 2;
						}
					} else if(length == 0b01111111) {
						if(payload.length >= index + 8) {
							ubyte[8] bytes = payload[index..index+8];
							length = bigEndianToNative!ulong(bytes).to!size_t;
							length += 8;
						}
					}
					if(payload.length >= index + length) {
						if(!masked) {
							this.onReceive(payload[index..index+length]);
						} else if(payload.length == index + length + 4) {
							immutable index4 = index + 4;
							ubyte[4] mask = payload[index..index4];
							payload = payload[index4..index4+length];
							foreach(i, ref ubyte p; payload) {
								p ^= mask[i % 4];
							}
							this.onReceive(payload);
						}
					}
				}
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
		ubyte[] header = [0b10000001];
		if(data.length < 0b01111110) {
			header ~= data.length & 255;
		} else if(data.length < ushort.max) {
			header ~= 0b01111110;
			header ~= nativeToBigEndian(cast(ushort)data.length);
		} else {
			header ~= 0b01111111;
			header ~= nativeToBigEndian(cast(ulong)data.length);
		}
		this.conn.send(header ~ cast(ubyte[])data);
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
