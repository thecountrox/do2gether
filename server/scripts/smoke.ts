import { startServer } from '../src/index.ts';

const h = await startServer(0);
const base = `http://127.0.0.1:${h.port}`;

const health = await fetch(`${base}/health`);
console.log('GET /health', health.status, await health.text());

const created = await fetch(`${base}/rooms`, { method: 'POST' });
const body = (await created.json()) as { room_id: string; join_token: string };
console.log('POST /rooms', created.status, JSON.stringify(body));
console.log('room registered:', h.rooms.has(body.room_id));
console.log('token parts:', body.join_token.split('.').length === 2);

const missing = await fetch(`${base}/nope`);
console.log('GET /nope', missing.status);

await h.close();
console.log('closed cleanly');
