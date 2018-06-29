module lighttp.server;

import std.system : Endian;

import libasync;

import xbuffer;
import xbuffer.memory : xalloc, xfree;

import lighttp.router;
import lighttp.util;

private enum defaultName = "lighttp/0.2";

/**
 * Base class for servers.
 */
abstract class ServerBase {

	private string _name;
	private EventLoop _eventLoop;
	private Router _router;

	this(EventLoop eventLoop, string name=defaultName) {
		_name = name;
		_eventLoop = eventLoop;
		_router = new Router();
	}

	this(string name=defaultName) {
		this(getThreadEventLoop(), name);
	}

	/**
	 * Gets/sets the server's name. It it the value displayed in
	 * the "Server" HTTP header value and in the footer of default
	 * error message pages.
	 */
	@property string name() pure nothrow @safe @nogc {
		return _name;
	}

	@property string name(string name) pure nothrow @safe @nogc {
		return _name = name;
	}

	/**
	 * Gets the server's event loop. It should be used to
	 * run the server.
	 * Example:
	 * ---
	 * auto server = new Server();
	 * server.host("0.0.0.0");
	 * while(true) server.eventLoop.loop();
	 * ---
	 */
	@property EventLoop eventLoop() pure nothrow @safe @nogc {
		return _eventLoop;
	}

	/**
	 * Gets the server's router.
	 */
	@property Router router() pure nothrow @safe @nogc {
		return _router;
	}
	
	/**
	 * Gets the server's default port.
	 */
	abstract @property ushort defaultPort() pure nothrow @safe @nogc;

	/**
	 * Binds the server to the given address.
	 * Example:
	 * ---
	 * server.host("0.0.0.0");
	 * server.host("::1", 8080);
	 * ---
	 */
	void host(string ip, ushort port) {
		auto listener = new AsyncTCPListener(this.eventLoop);
		listener.host(ip, port);
		listener.run(&this.handler);
	}

	/// ditto
	void host(string ip) {
		return this.host(ip, this.defaultPort);
	}

	/**
	 * Calls eventLoop.loop until the given condition
	 * is true.
	 */
	void loop(bool delegate() condition) {
		while(condition()) this.eventLoop.loop();
	}

	/**
	 * Calls eventLoop.loop in an infinite loop.
	 */
	void loop() {
		while(true) this.eventLoop.loop();
	}

	abstract void delegate(TCPEvent) handler(AsyncTCPConnection conn);

}

class ServerImpl(T:Connection, ushort _port) : ServerBase {

	this(E...)(E args) { //TODO remove when default constructors are implemented
		super(args);
	}

	override @property ushort defaultPort() {
		return _port;
	}

	override void delegate(TCPEvent) handler(AsyncTCPConnection conn) {
		Connection ret = new T(this, conn);
		return &ret.handle;
	}

}

/**
 * Default HTTP server.
 * Example:
 * ---
 * auto server = new Server();
 * server.host("0.0.0.0");
 * server.loop();
 * ---
 */
alias Server = ServerImpl!(DefaultConnection, 80);

class Connection {

	AsyncTCPConnection conn;

	protected Buffer buffer;

	protected this(size_t bufferSize) {
		this.buffer = xalloc!Buffer(bufferSize);
	}

	~this() {
		xfree(this.buffer);
	}

	void onStart() {}

	final void handle(TCPEvent event) {
		switch(event) with(TCPEvent) {
			case READ:
				this.buffer.reset();
				static ubyte[] buffer = new ubyte[4096];
				while(true) {
					auto len = this.conn.recv(buffer);
					if(len > 0) this.buffer.write(buffer[0..len]);
					if(len < buffer.length) break;
				}
				this.onRead();
				break;
			case CLOSE:
				this.onClose();
				//TODO schedule for destruction
				break;
			default:
				break;
		}
	}

	abstract void onRead();

	abstract void onClose();

}

class DefaultConnection : Connection {

	private ServerBase server;
	void delegate() _handle;

	this(ServerBase server, AsyncTCPConnection conn) {
		super(1024);
		this.server = server;
		this.conn = conn;
		_handle = &this.handle;
	}

	override void onRead() {
		_handle();
	}

	void handle() {
		Request request = new Request();
		Response response = new Response();
		response.headers["Server"] = this.server.name;
		HandleResult result;
		if(request.parse(this.buffer.data!char)) {
			try this.server.router.handle(result, this.conn, request, response);
			catch(Exception) response.status = StatusCodes.internalServerError;
		} else {
			response.status = StatusCodes.badRequest;
		}
		if(response.status.code >= 400 && response.body_.length == 0) this.server.router.handleError(request, response);
		this.conn.send(cast(ubyte[])response.toString());
		if(result.connection is null) {
			this.conn.kill();
		} else {
			_handle = &result.connection.onRead;
			result.connection.onStart();
		}
	}

	override void onClose() {}

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
class WebSocketConnection : Connection {

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
