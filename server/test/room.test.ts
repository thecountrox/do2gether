import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { after, afterEach, before, test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';
import { startServer, type ServerHandle } from '../src/index.ts';
import { signToken, verifyToken } from '../src/tokens.ts';

// ---------------------------------------------------------------------------
// Minimal JSON Schema validator for protocol/room.schema.json.
// Supports exactly the keywords that schema uses and throws on anything else,
// so a schema change can never be silently ignored.
// ---------------------------------------------------------------------------

type Json = Record<string, unknown>;

const SCHEMA = JSON.parse(
  readFileSync(new URL('../../protocol/room.schema.json', import.meta.url), 'utf8'),
) as Json;

const ANNOTATIONS = new Set(['$schema', '$id', 'title', 'description', '$defs', 'then', 'else']);

function isObj(v: unknown): v is Json {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function typeMatches(type: unknown, v: unknown): boolean {
  switch (type) {
    case 'object':
      return isObj(v);
    case 'array':
      return Array.isArray(v);
    case 'string':
      return typeof v === 'string';
    case 'integer':
      return Number.isInteger(v);
    case 'number':
      return typeof v === 'number' && Number.isFinite(v);
    case 'boolean':
      return typeof v === 'boolean';
    case 'null':
      return v === null;
    default:
      throw new Error(`validator: unsupported type ${String(type)}`);
  }
}

function validate(schema: Json, v: unknown, path = '$', errs: string[] = []): string[] {
  for (const [kw, arg] of Object.entries(schema)) {
    switch (kw) {
      case '$ref': {
        const target = (SCHEMA.$defs as Record<string, Json>)[String(arg).replace(/^#\/\$defs\//, '')];
        if (!target) throw new Error(`validator: unresolved $ref ${String(arg)}`);
        validate(target, v, path, errs);
        break;
      }
      case 'type': {
        const types: unknown[] = Array.isArray(arg) ? arg : [arg];
        if (!types.some((t) => typeMatches(t, v))) errs.push(`${path}: expected ${types.join('|')}`);
        break;
      }
      case 'const':
        if (v !== arg) errs.push(`${path}: expected ${JSON.stringify(arg)}`);
        break;
      case 'enum':
        if (!(arg as unknown[]).includes(v)) errs.push(`${path}: ${JSON.stringify(v)} not in enum`);
        break;
      case 'required':
        if (isObj(v)) {
          for (const k of arg as string[]) if (!(k in v)) errs.push(`${path}.${k}: required`);
        }
        break;
      case 'properties':
        if (isObj(v)) {
          for (const [k, sub] of Object.entries(arg as Record<string, Json>)) {
            if (k in v) validate(sub, v[k], `${path}.${k}`, errs);
          }
        }
        break;
      case 'items':
        if (Array.isArray(v)) v.forEach((x, i) => validate(arg as Json, x, `${path}[${i}]`, errs));
        break;
      case 'allOf':
        for (const sub of arg as Json[]) validate(sub, v, path, errs);
        break;
      case 'anyOf':
        if (!(arg as Json[]).some((sub) => validate(sub, v, path).length === 0)) {
          errs.push(`${path}: matches no anyOf branch`);
        }
        break;
      case 'if': {
        const branch = validate(arg as Json, v, path).length === 0 ? schema.then : schema.else;
        if (isObj(branch)) validate(branch, v, path, errs);
        break;
      }
      case 'pattern':
        if (typeof v === 'string' && !new RegExp(String(arg)).test(v)) errs.push(`${path}: does not match pattern`);
        break;
      case 'minimum':
        if (typeof v === 'number' && v < Number(arg)) errs.push(`${path}: below minimum ${String(arg)}`);
        break;
      case 'maximum':
        if (typeof v === 'number' && v > Number(arg)) errs.push(`${path}: above maximum ${String(arg)}`);
        break;
      case 'minLength':
        if (typeof v === 'string' && [...v].length < Number(arg)) errs.push(`${path}: shorter than ${String(arg)}`);
        break;
      case 'maxLength':
        if (typeof v === 'string' && [...v].length > Number(arg)) errs.push(`${path}: longer than ${String(arg)}`);
        break;
      default:
        if (!ANNOTATIONS.has(kw)) throw new Error(`validator: unsupported keyword ${kw}`);
    }
  }
  return errs;
}

// ---------------------------------------------------------------------------
// Harness: one in-process server on port 0, real `ws` clients.
// ---------------------------------------------------------------------------

interface Playback {
  item_ref: string;
  anchor_server_ms: number;
  position_ms: number;
  rate: number;
  paused: boolean;
}

interface QueueItem {
  item_ref: string;
}

interface Msg {
  v: number;
  t: string;
  room: string;
  seq: number;
  ts: number;
  from: string;
  [k: string]: unknown;
}

interface StateMsg extends Msg {
  rev: number;
  playback: Playback | null;
  queue: QueueItem[];
}

interface WelcomeMsg extends Msg {
  snapshot: { rev: number; playback: Playback | null; queue: QueueItem[]; presence: { user_id: string }[] };
  server_now: number;
}

interface PongMsg extends Msg {
  ping_id: string;
  t0: number;
  t1: number;
  t2: number;
}

interface PresenceMsg extends Msg {
  user_id: string;
  action: 'join' | 'leave';
}

interface RoomInfo {
  room_id: string;
  join_token: string;
}

interface Client {
  id: string;
  /** Every message received from the server, in arrival order. */
  log: Msg[];
  /** Sends a schema-valid message; the envelope fields are filled in. */
  send(t: string, body: Json): void;
  /** Sends raw text, bypassing schema checks (for malformed-input tests). */
  sendRaw(data: string): void;
  /** Resolves with the first not-yet-consumed message matching `match`. */
  next<T extends Msg = Msg>(match: string | ((m: Msg) => boolean), timeoutMs?: number): Promise<T>;
  close(): Promise<void>;
}

const FILM = `file:sha256p:1073741824:${'a'.repeat(32)}:${'b'.repeat(32)}`;
const SONG = 'subsonic:navidrome/tr-0001';
const CLIP = 'yt:dQw4w9WgXcQ';

let server: ServerHandle;
let host: string;
const sockets = new Set<WebSocket>();
const schemaErrors: string[] = [];
let syncCounter = 0;

before(async () => {
  server = await startServer(0);
  host = `127.0.0.1:${server.port}`;
});

after(() => server.close());

afterEach(async () => {
  await Promise.all([...sockets].map(closeSocket));
  sockets.clear();
  assert.deepEqual(schemaErrors.splice(0), [], 'every server message must validate against room.schema.json');
});

async function closeSocket(ws: WebSocket): Promise<void> {
  if (ws.readyState === WebSocket.CLOSED) return;
  const closed = once(ws, 'close');
  ws.close();
  await closed;
}

function wsUrl(roomId: string, token: string): string {
  return `ws://${host}/ws?room=${encodeURIComponent(roomId)}&token=${encodeURIComponent(token)}`;
}

async function createRoom(): Promise<RoomInfo> {
  const res = await fetch(`http://${host}/rooms`, { method: 'POST' });
  assert.equal(res.status, 201);
  return (await res.json()) as RoomInfo;
}

async function connect(id: string, room: RoomInfo): Promise<Client> {
  const ws = new WebSocket(wsUrl(room.room_id, room.join_token));
  sockets.add(ws);
  ws.on('error', () => {}); // surfaced through close codes / timeouts instead
  const log: Msg[] = [];
  const inbox: Msg[] = [];
  const waiters = new Set<{ pred: (m: Msg) => boolean; resolve: (m: Msg) => void }>();
  let seq = 0;

  ws.on('message', (data) => {
    const m = JSON.parse(String(data)) as Msg;
    for (const e of validate(SCHEMA, m)) schemaErrors.push(`${m.t} -> ${id}: ${e}`);
    log.push(m);
    for (const w of waiters) {
      if (w.pred(m)) {
        waiters.delete(w);
        w.resolve(m);
        return;
      }
    }
    inbox.push(m);
  });
  await once(ws, 'open');

  return {
    id,
    log,
    send(t: string, body: Json): void {
      const msg = { v: 1, t, room: room.room_id, seq: seq++, ts: Date.now(), from: id, ...body };
      assert.deepEqual(validate(SCHEMA, msg), [], `test tried to send an off-schema ${t}`);
      ws.send(JSON.stringify(msg));
    },
    sendRaw(data: string): void {
      ws.send(data);
    },
    next<T extends Msg = Msg>(match: string | ((m: Msg) => boolean), timeoutMs = 1000): Promise<T> {
      const pred = typeof match === 'string' ? (m: Msg): boolean => m.t === match : match;
      const i = inbox.findIndex(pred);
      if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0] as T);
      return new Promise((resolve, reject) => {
        const waiter = {
          pred,
          resolve: (m: Msg): void => {
            clearTimeout(timer);
            resolve(m as T);
          },
        };
        const timer = setTimeout(() => {
          waiters.delete(waiter);
          reject(new Error(`${id}: no matching message within ${timeoutMs} ms (${String(match)})`));
        }, timeoutMs);
        waiters.add(waiter);
      });
    },
    close: () => closeSocket(ws),
  };
}

async function join(id: string, room: RoomInfo): Promise<{ client: Client; welcome: WelcomeMsg }> {
  const client = await connect(id, room);
  client.send('hello', { proto: 1, client: { id, name: id, ver: 'test' } });
  return { client, welcome: await client.next<WelcomeMsg>('welcome') };
}

function intent(c: Client, op: string, args: Json = {}): void {
  c.send('intent', { op, args });
}

/** Clock round-trip: once the pong arrives, everything this client sent earlier has been processed. */
async function sync(c: Client): Promise<void> {
  const ping_id = `sync-${syncCounter++}`;
  c.send('clock_ping', { ping_id, t0: Date.now() });
  await c.next((m) => m.t === 'clock_pong' && m.ping_id === ping_id);
}

/** Opens a socket, immediately sends `hello`, and reports how the server closed it. */
async function connectExpectingClose(roomId: string, token: string): Promise<{ code: number; messages: number }> {
  const ws = new WebSocket(wsUrl(roomId, token));
  sockets.add(ws);
  ws.on('error', () => {});
  let messages = 0;
  ws.on('message', () => messages++);
  ws.on('open', () => {
    const hello = { proto: 1, client: { id: 'intruder', name: 'intruder', ver: 'test' } };
    ws.send(JSON.stringify({ v: 1, t: 'hello', room: roomId, seq: 0, ts: Date.now(), from: 'intruder', ...hello }));
  });
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(1000) }).catch(() => {
    throw new Error('server did not close the socket within 1000 ms');
  });
  const [code] = (await closed) as [number, Buffer];
  return { code, messages };
}

function positionAt(pb: Playback, now: number): number {
  return pb.paused ? pb.position_ms : pb.position_ms + (now - pb.anchor_server_ms) * pb.rate;
}

function assertStrictlyIncreasing(xs: number[], label: string): void {
  xs.forEach((x, i) => {
    if (i > 0) assert.ok(x > xs[i - 1]!, `${label} not strictly increasing: ${xs.join(', ')}`);
  });
}

function presenceIds(w: WelcomeMsg): string[] {
  return w.snapshot.presence.map((m) => m.user_id).sort();
}

// ---------------------------------------------------------------------------
// Acceptance criteria (TASK.md)
// ---------------------------------------------------------------------------

test('harness: schema validator accepts valid and rejects off-schema messages', () => {
  const ok: Json = { v: 1, t: 'state', room: 'r', seq: 0, ts: 0, from: 'server', rev: 0, playback: null, queue: [] };
  assert.deepEqual(validate(SCHEMA, ok), []);
  const badPlayback = { item_ref: 'bogus', anchor_server_ms: 1.5, position_ms: -1, rate: 1, paused: false };
  assert.ok(validate(SCHEMA, { ...ok, playback: badPlayback }).length > 0);
  assert.ok(validate(SCHEMA, { ...ok, t: 'nope' }).length > 0);
  const noRev = { ...ok };
  delete noRev.rev;
  assert.ok(validate(SCHEMA, noRev).length > 0);
});

test('AC1: POST /rooms returns room id + join token; two rooms get different ids', async () => {
  const res = await fetch(`http://${host}/rooms`, { method: 'POST' });
  assert.equal(res.status, 201);
  assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
  const a = (await res.json()) as RoomInfo;
  const b = await createRoom();

  for (const r of [a, b]) {
    assert.match(r.room_id, /^[0-9a-z]{8}$/);
    assert.ok(verifyToken(r.join_token, r.room_id));
    assert.ok(server.rooms.has(r.room_id), 'room exists server-side');
  }
  assert.notEqual(a.room_id, b.room_id);
  assert.ok(!verifyToken(a.join_token, b.room_id), 'token is bound to its room');

  // Token format: base64url({"room","exp"}) "." base64url(HMAC-SHA256(room:exp)), 10 minute TTL.
  const parts = a.join_token.split('.');
  assert.equal(parts.length, 2);
  const [payload, sig] = parts;
  assert.ok(payload && sig);
  const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as { room: string; exp: number };
  assert.equal(decoded.room, a.room_id);
  const ttl = decoded.exp - Date.now();
  assert.ok(ttl > 9 * 60_000 && ttl <= 10 * 60_000, `ttl ${ttl}`);
  const expectedSig = createHmac('sha256', process.env.WT_SECRET || 'dev-secret')
    .update(`${decoded.room}:${decoded.exp}`)
    .digest('base64url');
  assert.equal(sig, expectedSig);
});

test('AC2: bad, wrong-room, tampered and expired tokens are closed with 4001 and never join', async () => {
  const room = await createRoom();
  const other = await createRoom();
  const { client: observer } = await join('observer', room);

  const [payload = '', sig = ''] = room.join_token.split('.');
  const claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as Json;
  const extended = Buffer.from(JSON.stringify({ ...claims, exp: Number(claims.exp) + 3_600_000 })).toString('base64url');

  const expired = signToken(room.room_id, 100);
  assert.ok(verifyToken(expired, room.room_id), 'short-TTL token is valid before expiry');
  await sleep(150);
  assert.ok(!verifyToken(expired, room.room_id), 'short-TTL token fails after expiry');

  const cases: [string, string][] = [
    ['garbage', 'not-a-token'],
    ['empty', ''],
    ['wrong room', other.join_token],
    ['tampered exp', `${extended}.${sig}`],
    ['expired', expired],
  ];
  for (const [label, token] of cases) {
    const { code, messages } = await connectExpectingClose(room.room_id, token);
    assert.equal(code, 4001, `${label}: close code`);
    assert.equal(messages, 0, `${label}: no messages before close`);
  }

  assert.equal(server.rooms.get(room.room_id)?.clients.size, 1, 'only the observer is attached');
  await sync(observer);
  assert.deepEqual(
    observer.log.filter((m) => m.t === 'presence'),
    [],
    'no presence join for rejected sockets',
  );
});

test('AC3: hello -> welcome; presence contains the joining client once a second client joins', async () => {
  const room = await createRoom();
  const { client: a, welcome: wa } = await join('alice', room);
  assert.equal(wa.room, room.room_id);
  assert.equal(wa.snapshot.rev, 0);
  assert.equal(wa.snapshot.playback, null);
  assert.deepEqual(wa.snapshot.queue, []);
  assert.deepEqual(presenceIds(wa), ['alice']);
  assert.ok(Math.abs(wa.server_now - Date.now()) < 1000, 'server_now is server ms');

  // A hello with the wrong proto is ignored: no welcome, no membership.
  const c = await connect('mallory', room);
  c.sendRaw(
    JSON.stringify({
      v: 1, t: 'hello', room: room.room_id, seq: 0, ts: Date.now(), from: 'mallory',
      proto: 2, client: { id: 'mallory', name: 'mallory', ver: 'test' },
    }),
  );

  const { client: b, welcome: wb } = await join('bob', room);
  assert.deepEqual(presenceIds(wb), ['alice', 'bob']);

  const joined = await a.next<PresenceMsg>('presence');
  assert.equal(joined.user_id, 'bob');
  assert.equal(joined.action, 'join');

  await sync(b);
  assert.ok(!b.log.some((m) => m.t === 'presence'), 'joiner does not get its own presence join');
  assert.ok(!c.log.some((m) => m.t === 'welcome'), 'proto != 1 gets no welcome');
});

test('AC4: clock offset over 10 pings is within ±50 ms on the same machine', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const offsets: number[] = [];
  for (let i = 0; i < 10; i++) {
    const ping_id = `p${i}`;
    const t0 = Date.now();
    a.send('clock_ping', { ping_id, t0 });
    const pong = await a.next<PongMsg>((m) => m.t === 'clock_pong' && m.ping_id === ping_id);
    const t3 = Date.now();
    assert.equal(pong.t0, t0, 't0 echoed');
    assert.ok(t0 <= pong.t1 && pong.t1 <= pong.t2 && pong.t2 <= t3, `t0..t3 ordered: ${t0} ${pong.t1} ${pong.t2} ${t3}`);
    offsets.push((pong.t1 - t0 + (pong.t2 - t3)) / 2);
  }
  offsets.sort((x, y) => x - y);
  const median = ((offsets[4] ?? NaN) + (offsets[5] ?? NaN)) / 2;
  assert.ok(Math.abs(median) <= 50, `median offset ${median} ms`);
});

test('AC5: play from A reaches B as state with paused:false and a valid anchor within 500 ms', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const { client: b } = await join('bob', room);
  await a.next('presence');

  intent(a, 'play', {}); // rejected: nothing playing and no item_ref
  const sentAt = Date.now();
  intent(a, 'play', { item_ref: FILM });
  const s = await b.next<StateMsg>('state', 500);
  const receivedAt = Date.now();

  assert.ok(receivedAt - sentAt < 500, `latency ${receivedAt - sentAt} ms`);
  assert.equal(s.rev, 1, 'the rejected play did not count');
  assert.ok(s.playback);
  assert.equal(s.playback.item_ref, FILM);
  assert.equal(s.playback.paused, false);
  assert.equal(s.playback.rate, 1);
  assert.equal(s.playback.position_ms, 0);
  assert.ok(Number.isInteger(s.playback.anchor_server_ms));
  assert.ok(
    sentAt <= s.playback.anchor_server_ms && s.playback.anchor_server_ms <= receivedAt,
    'anchor is server now at accept time',
  );

  const own = await a.next<StateMsg>('state');
  assert.deepEqual(own, s, 'sender receives the identical broadcast');
});

test('AC6: pause freezes position_ms at the time elapsed since the play anchor', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  intent(a, 'play', { item_ref: FILM, position_ms: 0 });
  const played = await a.next<StateMsg>('state');
  assert.ok(played.playback);

  await sleep(300);
  intent(a, 'pause');
  const paused = await a.next<StateMsg>('state');
  const elapsed = Date.now() - played.playback.anchor_server_ms;

  assert.ok(paused.playback);
  assert.equal(paused.playback.paused, true);
  assert.equal(paused.playback.item_ref, FILM);
  assert.ok(paused.playback.position_ms >= 290, `position ${paused.playback.position_ms}`);
  assert.ok(
    Math.abs(paused.playback.position_ms - elapsed) <= 100,
    `position ${paused.playback.position_ms} vs elapsed ${elapsed}`,
  );
  assert.equal(
    paused.playback.position_ms,
    paused.playback.anchor_server_ms - played.playback.anchor_server_ms,
    'anchor reset to pause time; position advanced 1:1 at rate 1',
  );
});

test('AC7: seek 42000 yields position_ms === 42000 and preserves item/rate/paused', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  intent(a, 'play', { item_ref: FILM });
  const played = await a.next<StateMsg>('state');
  assert.ok(played.playback);

  intent(a, 'seek', { position_ms: 42000 });
  const s = await a.next<StateMsg>('state');
  assert.ok(s.playback);
  assert.equal(s.playback.position_ms, 42000);
  assert.equal(s.playback.item_ref, FILM);
  assert.equal(s.playback.rate, 1);
  assert.equal(s.playback.paused, false);
  assert.ok(s.playback.anchor_server_ms >= played.playback.anchor_server_ms);

  intent(a, 'pause');
  await a.next('state');
  intent(a, 'seek', { position_ms: 1000 });
  const s2 = await a.next<StateMsg>('state');
  assert.ok(s2.playback);
  assert.equal(s2.playback.position_ms, 1000);
  assert.equal(s2.playback.paused, true, 'seek while paused stays paused');
});

test('AC8: rev and seq increase monotonically across five intents', async () => {
  const room = await createRoom();
  const { client: a, welcome: wa } = await join('alice', room);
  const { client: b, welcome: wb } = await join('bob', room);
  await a.next('presence');

  intent(a, 'seek', { position_ms: 5 }); // rejected: nothing playing
  const ops: [string, Json][] = [
    ['queue_add', { item_ref: SONG }],
    ['play', { item_ref: FILM }],
    ['seek', { position_ms: 42000 }],
    ['pause', {}],
    ['skip', {}],
  ];
  const seenA: StateMsg[] = [];
  const seenB: StateMsg[] = [];
  for (const [i, [op, args]] of ops.entries()) {
    intent(i % 2 === 0 ? a : b, op, args);
    seenA.push(await a.next<StateMsg>('state'));
    seenB.push(await b.next<StateMsg>('state'));
  }

  assert.deepEqual(seenA.map((s) => s.rev), [1, 2, 3, 4, 5]);
  assertStrictlyIncreasing([wa.seq, ...seenA.map((s) => s.seq)], 'seq (alice)');
  assertStrictlyIncreasing([wb.seq, ...seenB.map((s) => s.seq)], 'seq (bob)');
  assert.deepEqual(seenB, seenA, 'both clients see the same state stream');

  const last = seenA.at(-1);
  assert.ok(last?.playback);
  assert.equal(last.playback.item_ref, SONG, 'skip popped the queue head into playback');
  assert.equal(last.playback.position_ms, 0);
  assert.deepEqual(last.queue, []);
});

test('AC9: reconnecting client gets a welcome matching the latest state', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const { client: b } = await join('bob', room);

  intent(a, 'play', { item_ref: FILM, position_ms: 10_000 });
  await a.next('state');
  intent(a, 'seek', { position_ms: 60_000 });
  const latest = await a.next<StateMsg>('state');
  assert.ok(latest.playback);

  await b.close();
  const left = await a.next<PresenceMsg>((m) => m.t === 'presence' && m.action === 'leave');
  assert.equal(left.user_id, 'bob');
  assert.equal(server.rooms.get(room.room_id)?.clients.size, 1, 'presence removed on disconnect');

  await sleep(200);
  const { client: b2, welcome } = await join('bob', room);
  const receivedAt = Date.now();
  const pb = welcome.snapshot.playback;
  assert.ok(pb);
  assert.equal(welcome.snapshot.rev, latest.rev);
  assert.equal(pb.item_ref, latest.playback.item_ref);
  assert.equal(pb.paused, latest.playback.paused);
  const fromWelcome = positionAt(pb, welcome.server_now);
  const fromLatest = positionAt(latest.playback, receivedAt);
  assert.ok(Math.abs(fromWelcome - fromLatest) <= 150, `welcome ${fromWelcome} vs latest ${fromLatest}`);
  assert.ok(fromWelcome >= 60_190, `playback kept running while bob was away (${fromWelcome})`);
  assert.deepEqual(presenceIds(welcome), ['alice', 'bob'], 'no stale presence entry');

  // Same check while paused: position must match exactly.
  intent(a, 'pause');
  const pausedState = await a.next<StateMsg>('state');
  await b2.close();
  const { welcome: w3 } = await join('bob', room);
  assert.deepEqual(w3.snapshot.playback, pausedState.playback);
  assert.equal(w3.snapshot.rev, pausedState.rev);
});

test('AC10: report is accepted, stored per client, and never broadcast', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const { client: b } = await join('bob', room);
  await a.next('presence');

  const first = { offset_ms: 1.5, rtt_ms: 12, drift_ms: -30, source: 'mpv' };
  const second = { offset_ms: 2, rtt_ms: 9.5, drift_ms: 4, source: 'mpv' };
  a.send('report', { activity_id: null, observed: first });
  a.send('report', { activity_id: null, observed: second });
  await sync(a);

  const alice = [...(server.rooms.get(room.room_id)?.clients ?? [])].find((c) => c.member?.user_id === 'alice');
  assert.ok(alice?.report, 'report stored');
  assert.deepEqual(alice.report.observed, second, 'latest report wins');
  assert.equal(alice.report.activity_id, null);

  intent(a, 'play', { item_ref: CLIP });
  await b.next('state');
  await sleep(100);
  assert.deepEqual(b.log.map((m) => m.t), ['welcome', 'state'], 'bob saw no report');
  assert.ok(!a.log.some((m) => m.t === 'report'), 'report not echoed to sender');
});

// ---------------------------------------------------------------------------
// Other TASK.md behaviour
// ---------------------------------------------------------------------------

test('HTTP: GET /health is ok; everything else is 404', async () => {
  const health = await fetch(`http://${host}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true });

  for (const [method, path] of [['GET', '/'], ['GET', '/rooms'], ['POST', '/health'], ['GET', '/nope']] as const) {
    const res = await fetch(`http://${host}${path}`, { method });
    assert.equal(res.status, 404, `${method} ${path}`);
    await res.arrayBuffer();
  }
});

test('malformed JSON, non-v1 envelopes, unknown t and unknown ops are ignored without disconnecting', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const { client: b } = await join('bob', room);
  await a.next('presence');

  const env = { v: 1, room: room.room_id, seq: 0, ts: Date.now(), from: 'alice' };
  for (const raw of [
    '{not json',
    '',
    'null',
    '[]',
    '42',
    JSON.stringify({ ...env, v: 2, t: 'intent', op: 'play', args: { item_ref: FILM } }),
    JSON.stringify({ ...env, t: 'bogus' }),
    JSON.stringify({ ...env, t: 'intent', op: 'explode', args: {} }),
    JSON.stringify({ ...env, t: 'intent', op: 'play', args: 'nope' }),
    JSON.stringify({ ...env, t: 'intent', op: 'play', args: { item_ref: 'not-a-ref' } }),
  ]) {
    a.sendRaw(raw);
  }
  await sync(a);

  intent(a, 'play', { item_ref: FILM });
  const s = await b.next<StateMsg>('state');
  assert.equal(s.rev, 1, 'none of the ignored messages changed state');
  assert.deepEqual(b.log.map((m) => m.t), ['welcome', 'state']);
});

test('rooms are isolated', async () => {
  const r1 = await createRoom();
  const r2 = await createRoom();
  const { client: a } = await join('alice', r1);
  const { client: b, welcome } = await join('bob', r2);
  assert.deepEqual(presenceIds(welcome), ['bob']);

  intent(a, 'play', { item_ref: FILM });
  await a.next('state');
  await sync(b);
  assert.deepEqual(b.log.map((m) => m.t), ['welcome', 'clock_pong']);
  assert.equal(server.rooms.get(r2.room_id)?.playback, null);
  assert.equal(server.rooms.get(r2.room_id)?.rev, 0);
});

test('queue_add / queue_remove / skip', async () => {
  const room = await createRoom();
  const { client: a } = await join('alice', room);
  const step = async (op: string, args: Json = {}): Promise<StateMsg> => {
    intent(a, op, args);
    return a.next<StateMsg>('state');
  };

  assert.deepEqual((await step('queue_add', { item_ref: SONG })).queue, [{ item_ref: SONG }]);
  assert.deepEqual((await step('queue_add', { item_ref: CLIP })).queue, [{ item_ref: SONG }, { item_ref: CLIP }]);
  assert.deepEqual((await step('queue_remove', { item_ref: SONG })).queue, [{ item_ref: CLIP }]);

  const skipped = await step('skip');
  assert.deepEqual(skipped.queue, []);
  assert.ok(skipped.playback);
  assert.equal(skipped.playback.item_ref, CLIP);
  assert.equal(skipped.playback.position_ms, 0);
  assert.equal(skipped.playback.paused, false);

  const cleared = await step('skip');
  assert.equal(cleared.playback, null, 'skip with an empty queue clears playback');
  assert.equal(cleared.rev, 5);
});
