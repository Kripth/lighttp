/+ dub.sdl:
name "chat"
description "Simple chatroom using websockets"
dependency "lighttp" path=".."
+/
module app;

import std.json : JSONValue;
import std.regex : ctRegex;

import libasync;
import lighttp;

void main(string[] args) {

	auto server = new Server(new Chat());
	server.host("0.0.0.0", 80);
	
	while(true) server.eventLoop.loop();

}

class Chat : Router {

	@Get("/chat") Resource index;
	
	private Room[string] rooms;
	
	this() {
		this.index = new CachedResource("text/html", INDEX);
	}
	
	@Get(ctRegex!`\/room\/([a-z0-9]{2,16})@([a-zA-Z0-9]{3,16})`) class Client : WebSocketClient {
	
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

enum string INDEX = q{
<html>
	<head>
		<script>
			function join(room, username) {
				var ws = new WebSocket("ws://" + location.host + "/room/" + room + "@" + username);
				ws.onopen = function(){
					document.body.innerHTML = "<div id='messages'></div><input id='message' /><button id='send'>Send</button>";
					var send = function(){
						var message = document.getElementById("message");
						if(message.value.length > 0) {
							ws.send(message.value);
							message.value = "";
						}
					};
					document.getElementById("send").onclick = send;
					document.getElementById("message").onkeydown = function(event){
						if(event.keyCode == 13) send();
					}
				}
				ws.onmessage = function(message){
					var json = JSON.parse(message.data);
					var mx = (function(){
						switch(json.type) {
							case "join":
								return json.user.name + " joined";
							case "leave":
								return json.user.name + " left";
							case "message":
								return json.user.name + ": " + json.message;
						}
					})();
					console.log(mx);
					document.getElementById("messages").innerHTML += "<p>" + mx + "</p>";
				}
			}
		</script>
	</head>
	<body>
		<input placeholder="room" />
		<input placeholder="name" />
		<button onclick="join(document.getElementsByTagName('input')[0].value, document.getElementsByTagName('input')[1].value)">Connect</button>
	</body>
</html>
};
