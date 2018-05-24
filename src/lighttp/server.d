module lighttp.server;

import std.system : Endian;

import libasync;

import xbuffer;
import xbuffer.memory : alloc, free;

import lighttp.router;
import lighttp.util;

class Server {

	private EventLoop evl;
	private Router router;

	public immutable string name;

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

	void host(string ip) {
		return this.host(ip, this.defaultPort);
	}

	@property ushort defaultPort() pure nothrow @safe @nogc {
		return 80;
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
				static ubyte[] buffer = new ubyte[4092];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) req.write(buffer[0..len]);
					if(len < buffer.length) break;
				}
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
				if(response.status.code >= 400 && response.body_.length == 0) router.error(request, response);
				this.conn.send(cast(ubyte[])response.toString());
				if(result.connection is null) {
					this.conn.kill();
				} else {
					_handler = &result.connection.handle;
					result.connection.onStart();
				}
			}
		}

	}

}

class Connection {

	AsyncTCPConnection conn;

	protected Buffer buffer;

	protected this(size_t bufferSize) {
		this.buffer = alloc!Buffer(bufferSize);
	}

	~this() {
		free(this.buffer);
	}

	void onStart() {}

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
				this.onRead();
				break;
			case CLOSE:
				this.onClose();
				break;
			default:
				break;
		}
	}

	abstract void onRead();

	abstract void onClose();

}

class MultipartConnection : Connection {

	private size_t length;
	private Request req;
	void delegate() callback;

	this(AsyncTCPConnection conn, size_t length, Request req, void delegate() callback) {
		super(4096);
		this.conn = conn;
		this.length = length;
		this.req = req;
		this.callback = callback;
	}

	override void onRead() {
		this.req.body_ = this.req.body_ ~ this.buffer.data!char.idup;
		if(this.req.body_.length >= this.length) {
			this.callback();
			this.conn.kill();
		}
	}

	override void onClose() {}

}

/**
 * Base class for web socket clients.
 */
class WebSocketClient : Connection {

	void delegate() onStartImpl;

	this() {
		super(1024);
		this.onStartImpl = {};
	}

	override void onStart() {
		this.onStartImpl();
	}

	override void onRead() {
		try if((this.buffer.read!ubyte() & 0b1111) == 1) {
			immutable info = this.buffer.read!ubyte();
			immutable masked = (info & 0b10000000) != 0;
			size_t length = info & 0b01111111;
			if(length == 0b01111110) {
				length = this.buffer.read!(Endian.bigEndian, ushort)();
			} else if(length == 0b01111111) {
				length = this.buffer.read!(Endian.bigEndian, ulong)() & size_t.max;
			}
			if(masked) {
				ubyte[] mask = this.buffer.read!(ubyte[])(4);
				ubyte[] data = this.buffer.read!(ubyte[])(length);
				foreach(i, ref ubyte p; data) {
					p ^= mask[i % 4];
				}
				this.onReceive(data);
			} else {
				this.onReceive(this.buffer.read!(ubyte[])(length));
			}
		} catch(BufferOverflowException) {}
	}
	
	/**
	 * Sends data to the connected web socket.
	 */
	void send(in void[] data) {
		this.buffer.reset();
		this.buffer.write!ubyte(0b10000001);
		if(data.length < 0b01111110) {
			this.buffer.write!ubyte(data.length & ubyte.max);
		} else if(data.length < ushort.max) {
			this.buffer.write!ubyte(0b01111110);
			this.buffer.write!(Endian.bigEndian, ushort)(data.length & ushort.max);
		} else {
			this.buffer.write!ubyte(0b01111111);
			this.buffer.write!(Endian.bigEndian, ulong)(data.length);
		}
		this.buffer.write(data);
		this.conn.send(this.buffer.data!ubyte);
	}

	/**
	 * Notifies that the client has sent some data.
	 */
	abstract void onReceive(ubyte[] data);

	/**
	 * Notifies that the connection has been interrupted.
	 */
	override abstract void onClose();

}
