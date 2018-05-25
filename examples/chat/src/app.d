module app;

import std.file : read;
import std.json : JSONValue;
import std.regex : ctRegex;

import lighttp;

void main(string[] args) {

	auto server = new Server(new Chat());
	server.host("0.0.0.0", 80);
	
	while(true) server.eventLoop.loop();

}

class Chat : Router {

	@Get("") Resource index;
	
	private Room[string] rooms;
	
	this() {
		this.index = new CachedResource("text/html", read("res/chat.html"));
	}
	
	@Get(`room`, `([a-z0-9]{2,16})@([a-zA-Z0-9]{3,16})`) class Client : WebSocket {
	
		private static uint _id = 0;
	
		public uint id;
		public string name;
		private Room* room;
		
		void onConnect(NetworkAddress address, string room, string name) {
			this.id = _id++;
			this.name = name;
			if(room !in rooms) rooms[room] = new Room();
			this.room = room in rooms;
			this.room.add(this);
		}
		
		override void onClose() {
			this.room.remove(this);
		}
		
		override void onReceive(ubyte[] data) {
			this.room.broadcast(this, JSONValue(["type": "message", "message": cast(string)data]));
		}
	
	}

}

class Room {

	Chat.Client[uint] clients;
	
	void add(Chat.Client client) {
		this.clients[client.id] = client;
		this.broadcast(client, JSONValue(["type": "join"]));
	}
	
	void remove(Chat.Client client) {
		this.clients.remove(client.id);
		this.broadcast(client, JSONValue(["type": "leave"]));
	}
	
	void broadcast(Chat.Client client, JSONValue json) {
		json["user"] = ["id": JSONValue(client.id), "name": JSONValue(client.name)];
		string message = json.toString();
		foreach(client ; this.clients) client.send(message);
	}

}
