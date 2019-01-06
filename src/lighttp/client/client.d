module lighttp.client.client;

import std.conv : to, ConvException;

import libasync;

import lighttp.util;

import xbuffer : Buffer;

struct ClientOptions {

	bool closeOnSuccess = false;

	bool closeOnFailure = false;

	//bool followRedirect = false;

}

class Client {

	private EventLoop _eventLoop;
	private ClientOptions _options;

	this(EventLoop eventLoop, ClientOptions options=ClientOptions.init) {
		_eventLoop = eventLoop;
		_options = options;
	}

	this(ClientOptions options=ClientOptions.init) {
		this(getThreadEventLoop(), options);
	}

	@property ClientOptions options() pure nothrow @safe @nogc {
		return _options;
	}

	@property EventLoop eventLoop() pure nothrow @safe @nogc {
		return _eventLoop;
	}

	ClientConnection connect(string ip, ushort port=80) {
		return new ClientConnection(new AsyncTCPConnection(_eventLoop), ip, port);
	}

	class ClientConnection {

		private AsyncTCPConnection _connection;

		private bool _connected = false;
		private bool _performing = false;
		private bool _successful;

		private immutable string host;

		private Buffer _buffer;
		private size_t _contentLength;
		private void delegate() _handler;

		private ClientResponse _response;

		private void delegate(ClientResponse) _success;
		private void delegate() _failure;

		this(AsyncTCPConnection connection, string ip, ushort port) {
			_buffer = new Buffer(4096);
			_handler = &this.handleFirst;
			_success = (ClientResponse response){};
			_failure = {};
			_connection = connection;
			_connection.host(ip, port);
			_connection.run(&this.handler);
			this.host = ip ~ (port != 80 ? ":" ~ to!string(port) : "");
		}

		auto perform(ClientRequest request) {
			assert(!_performing);
			_performing = true;
			_successful = false;
			request.headers["Host"] = this.host;
			if(_connected) {
				_connection.send(cast(ubyte[])request.toString());
			} else {
				_buffer.reset();
				_buffer.write(request.toString());
			}
			return this;
		}
		
		auto get(string path) {
			return this.perform(new ClientRequest("GET", path));
		}
		
		auto post(string path, string body_) {
			return this.perform(new ClientRequest("POST", path, body_));
		}

		auto success(void delegate(ClientResponse) callback) {
			_success = callback;
			return this;
		}

		auto failure(void delegate() callback) {
			_failure = callback;
			return this;
		}

		bool close() {
			return _connection.kill();
		}
		
		private void handler(TCPEvent event) {
			switch(event) with(TCPEvent) {
				case CONNECT:
					_connected = true;
					if(_buffer.data.length) _connection.send(_buffer.data!ubyte);
					break;
				case READ:
					static ubyte[] __buffer = new ubyte[4096];
					_buffer.reset();
					while(true) {
						auto len = _connection.recv(__buffer);
						if(len > 0) _buffer.write(__buffer[0..len]);
						if(len < __buffer.length) break;
					}
					_handler();
					break;
				case CLOSE:
					if(!_successful) _failure();
					break;
				default:
					break;
			}
		}
		
		private void handleFirst() {
			ClientResponse response = new ClientResponse();
			if(response.parse(_buffer.data!char)) {
				if(auto contentLength = "content-length" in response.headers) {
					try {
						_contentLength = to!size_t(*contentLength);
						if(_contentLength > response.body_.length) {
							_handler = &this.handleLong;
							_response = response;
							return;
						}
					} catch(ConvException) {
						_performing = false;
						_successful = false;
						_failure();
						if(_options.closeOnFailure) this.close();
						return;
					}
				}
				_performing = false;
				_successful = true;
				_success(response);
				if(_options.closeOnSuccess) this.close();
			} else {
				_performing = false;
				_successful = false;
				_failure();
				if(_options.closeOnFailure) this.close();
			}
		}

		private void handleLong() {
			_response.body_ = _response.body_ ~ _buffer.data!char;
			if(_response.body_.length >= _contentLength) {
				_performing = false;
				_successful = true;
				_success(_response);
				if(_options.closeOnSuccess) this.close();
			}
		}

	}

}
