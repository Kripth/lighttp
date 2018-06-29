module lighttp;

public import libasync : NetworkAddress;

public import lighttp.resource : Resource, CachedResource, TemplatedResource;
public import lighttp.router : CustomMethod, Get, Post, Multipart;
public import lighttp.server : Server, WebSocket = WebSocketConnection;
public import lighttp.util : StatusCodes, Request, Response;

deprecated("Use WebSocket instead") alias WebSocketClient = WebSocket;
