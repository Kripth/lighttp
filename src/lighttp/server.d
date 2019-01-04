module lighttp.server;

import std.string : toLower;
import std.system : Endian;

import libasync;

import xbuffer;
import xbuffer.memory : xalloc, xfree;

import lighttp.router;
import lighttp.util;

/**
 * Options to define how the server behaves.
 */
struct ServerOptions {

	/**
	 * Name of the server set as value in the `Server` header field
	 * and displayed in lighttp's default error messages.
	 */
	string name = "lighttp/0.5";

	/**
	 * Indicates whether the handler should catch exceptions.
	 * If set to true the server will return a `500 Internal Server Error`
	 * upon catching an exception.
	 */
	bool handleExceptions = true;

	/**
	 * Indicates the maximum size for a payload. If the header
	 * `Content-Length` sent by the client exceeds the indicated
	 * length the server will return a `413 Payload too Large`.
	 */
	size_t max = size_t.max;

}

/**
 * Base class for servers.
 */
abstract class ServerBase {
	
	private ServerOptions _options;
	private EventLoop _eventLoop;
	private Router _router;
	
	this(EventLoop eventLoop, ServerOptions options=ServerOptions.init) {
		_options = options;
		_eventLoop = eventLoop;
		_router = new Router();
	}
	
	this(ServerOptions options=ServerOptions.init) {
		this(getThreadEventLoop(), options);
	}

	/**
	 * Gets the server's options.
	 */
	@property ServerOptions options() pure nothrow @safe @nogc {
		return _options;
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
	void run(bool delegate() condition) {
		while(condition()) this.eventLoop.loop();
	}
	
	/**
	 * Calls eventLoop.loop in an infinite loop.
	 */
	void run() {
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

private ubyte[] __buffer = new ubyte[2 ^^ 24]; // 16 mb

class Connection {
	
	AsyncTCPConnection conn;
	
	protected Buffer buffer;
	
	void onStart() {}

	protected bool log=false;
	
	final void handle(TCPEvent event) {
		switch(event) with(TCPEvent) {
			case READ:
				this.buffer.reset();
				while(true) {
					auto len = this.conn.recv(__buffer);
					if(len > 0) this.buffer.write(__buffer[0..len]);
					if(len < __buffer.length) break;
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

class DefaultConnection : Connection {
	
	private ServerBase server;

	private void delegate() _handle;
	private void delegate(ref HandleResult, AsyncTCPConnection, ServerRequest, ServerResponse) _handleRoute;
	
	this(ServerBase server, AsyncTCPConnection conn) {
		this.buffer = new Buffer(4096);
		this.server = server;
		this.conn = conn;
		_handle = &this.handle;
		if(this.server.options.handleExceptions) _handleRoute = &this.handleRouteCatch;
		else _handleRoute = &this.handleRouteNoCatch;
	}
	
	override void onRead() {
		_handle();
	}

	private void handleRouteCatch(ref HandleResult result, AsyncTCPConnection client, ServerRequest req, ServerResponse res) {
		try this.server.router.handle(this.server.options, result, client, req, res);
		catch(Exception) res.status = StatusCodes.internalServerError;
	}

	private void handleRouteNoCatch(ref HandleResult result, AsyncTCPConnection client, ServerRequest req, ServerResponse res) {
		this.server.router.handle(this.server.options, result, client, req, res);
	}

	void handle() {
		handleImpl(this.buffer.data!char);
	}
	
	protected void handleImpl(string data) {
		ServerRequest request = new ServerRequest();
		ServerResponse response = new ServerResponse();
		request.address = this.conn.local;
		response.headers["Server"] = this.server.options.name;
		HandleResult result;
		if(request.parse(data)) {
			//TODO max request size
			if(auto connection = "connection" in request.headers) response.headers["Connection"] = *connection;
			_handleRoute(result, this.conn, request, response);
		} else {
			response.status = StatusCodes.badRequest;
		}
		if(response.status.code >= 400 && response.body_.length == 0) this.server.router.handleError(request, response);
		if(response.ready) this.conn.send(cast(ubyte[])response.toString());
		auto connection = "connection" in response.headers;
		if(result.connection !is null) {
			_handle = &result.connection.onRead;
			result.connection.buffer = this.buffer;
			result.connection.onStart();
		} else if(connection is null || toLower(*connection) != "keep-alive") {
			this.conn.kill();
		}
	}
	
	override void onClose() {}
	
}

class MultipartConnection : Connection {
	
	private size_t length;
	private Http req, res;
	void delegate() callback;
	
	this(AsyncTCPConnection conn, size_t length, Http req, Http res, void delegate() callback) {
		this.conn = conn;
		this.length = length;
		this.req = req;
		this.res = res;
		this.callback = callback;
	}
	
	override void onRead() {
		this.req.body_ = this.req.body_ ~ this.buffer.data!char.idup;
		import std.stdio;
		writeln("Body is not ", this.req.body_.length);
		if(this.req.body_.length >= this.length) {
			this.callback();
			this.conn.send(cast(ubyte[])res.toString());
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