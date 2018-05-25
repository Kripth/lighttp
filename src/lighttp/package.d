module lighttp;

public import libasync : NetworkAddress;

public import lighttp.router : Router, CustomMethod, Get, Post, Multipart;
public import lighttp.server : Server, WebSocket = WebSocketConnection;
public import lighttp.util : StatusCodes, Request, Response, Resource, CachedResource;

deprecated("Use WebSocket instead") alias WebSocketClient = WebSocket;
