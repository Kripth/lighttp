module app;

import std.file : read;
import std.json : JSONValue;
import std.regex : ctRegex;

import lighttp;

void main(string[] args) {

	auto server = new Server();
	server.host("0.0.0.0");
	server.host("::");
	server.router.add(new Chat());
	server.run();

}

class Chat {

	@Get("") Resource index;
	
	private Room[string] rooms;
	
	this() {
		this.index = new CachedResource("text/html", read("res/chat.html"));
	}
	
	@Get(`room`, `([a-z0-9]{1,16})@([a-zA-Z0-9_]{1,32})`) class Client : WebSocket {
	
		private static uint _id = 0;
	
		public uint id;
		public string ip;
		public string name;
		private Room* room;
		
		void onConnect(Address address, string room, string name) {
			this.id = _id++;
			this.ip = address.toAddrString();
			this.name = name;
			if(room !in rooms) rooms[room] = new Room();
			this.room = room in rooms;
			this.room.add(this);
		}
		
		override void onClose() {
			this.room.remove(this);
		}
		
		override void onReceive(ubyte[] data) {
			this.room.broadcast(JSONValue(["type": JSONValue("message"), "sender": JSONValue(this.id), "message": JSONValue(cast(string)data)]));
		}
	
	}

}

class Room {

	Chat.Client[uint] clients;
	
	void add(Chat.Client client) {
		// send current clients to the new client
		if(this.clients.length) {
			JSONValue[] clients;
			foreach(c ; this.clients) {
				clients ~= JSONValue(["id": JSONValue(c.id), "ip": JSONValue(c.ip), "name": JSONValue(c.name)]);
			}
			client.send(JSONValue(["type": JSONValue("list"), "list": JSONValue(clients)]).toString());
		}
		// add to list and send new client to other clients
		this.clients[client.id] = client;
		this.broadcast(JSONValue(["type": JSONValue("add"), "id": JSONValue(client.id), "ip": JSONValue(client.ip), "name": JSONValue(client.name)]));
	}
	
	void remove(Chat.Client client) {
		// remove client and broadcast message
		this.clients.remove(client.id);
		this.broadcast(JSONValue(["type": JSONValue("remove"), "id": JSONValue(client.id)]));
	}
	
	void broadcast(JSONValue json) {
		string message = json.toString();
		foreach(client ; this.clients) client.send(message);
	}

}
