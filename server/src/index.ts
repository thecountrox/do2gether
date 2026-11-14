import { randomBytes, randomInt } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { WebSocketServer, type WebSocket } from 'ws';
import { serverNow } from './clock.ts';
import { attach, createRoom, detach, handleMessage, type Room } from './room.ts';
import { signToken, verifyToken } from './tokens.ts';

export interface ServerHandle {
  port: number;
  rooms: Map<string, Room>;
  close(): Promise<void>;
}

const MAX_PAYLOAD_BYTES = 64 * 1024;

function newRoomId(rooms: Map<string, Room>): string {
  for (;;) {
    let id = '';
    for (let i = 0; i < 8; i++) id += randomInt(36).toString(36);
    if (!rooms.has(id)) return id;
  }
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body));
}

function onRequest(rooms: Map<string, Room>, req: IncomingMessage, res: ServerResponse): void {
  const url = URL.parse(req.url ?? '/', 'http://localhost');
  if (req.method === 'POST' && url?.pathname === '/rooms') {
    const id = newRoomId(rooms);
    const room = createRoom(id);
    room.hostId = `host-${randomBytes(6).toString('hex')}`;
    rooms.set(id, room);
    sendJson(res, 201, { room_id: id, join_token: signToken(id), host_id: room.hostId });
  } else if (req.method === 'GET' && url?.pathname?.startsWith('/rooms/')) {
    const id = url.pathname.slice('/rooms/'.length);
    const room = rooms.get(id);
    if (!room || !id || id.includes('/')) {
      res.writeHead(404).end();
      return;
    }
    const members = [...room.clients].flatMap((c) => c.member ? [c.member] : []);
    sendJson(res, 200, {
      room_id: id,
      host_name: members.find((m) => m.user_id === room.hostId)?.name ?? 'Host',
      member_count: members.length,
      playback: room.playback,
    });
  } else if (req.method === 'GET' && url?.pathname === '/health') {
    sendJson(res, 200, { ok: true });
  } else {
    res.writeHead(404).end();
  }
}

function onConnection(rooms: Map<string, Room>, ws: WebSocket, params: URLSearchParams): void {
  ws.on('error', (err) => console.error(`[ws] ${err.message}`));
  const roomId = params.get('room') ?? '';
  if (!verifyToken(params.get('token') ?? '', roomId)) {
    ws.close(4001, 'invalid token');
    return;
  }
  const room = rooms.get(roomId);
  if (!room) {
    ws.close(4004, 'room not found');
    return;
  }
  const client = attach(room, { send: (data) => ws.send(data) });
  ws.on('message', (data) => handleMessage(room, client, data.toString(), serverNow()));
  ws.on('close', () => detach(room, client));
}

function closeServer(server: Server, wss: WebSocketServer): Promise<void> {
  for (const ws of wss.clients) ws.terminate();
  wss.close();
  server.closeAllConnections();
  return new Promise((resolve) => server.close(() => resolve()));
}

export function startServer(port: number): Promise<ServerHandle> {
  const rooms = new Map<string, Room>();
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD_BYTES });
  const server = createServer((req, res) => onRequest(rooms, req, res));

  server.on('upgrade', (req, socket, head) => {
    const url = URL.parse(req.url ?? '/', 'http://localhost');
    if (!url || url.pathname !== '/ws') {
      socket.on('error', () => socket.destroy());
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => onConnection(rooms, ws, url.searchParams));
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, () => {
      const address = server.address();
      const actualPort = typeof address === 'object' && address !== null ? address.port : port;
      resolve({ port: actualPort, rooms, close: () => closeServer(server, wss) });
    });
  });
}

if (import.meta.main) {
  const handle = await startServer(Number(process.env.PORT ?? 8787));
  console.log(`watch-together server listening on :${handle.port}`);
}
