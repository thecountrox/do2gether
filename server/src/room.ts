import { serverNow } from './clock.ts';

const ITEM_REF =
  /^(file:sha256p:[0-9]+:[0-9a-f]{32}:[0-9a-f]{32}|yt:[A-Za-z0-9_-]{11}|ytm:[A-Za-z0-9_-]{11}|subsonic:[a-z0-9-]+\/[A-Za-z0-9_-]+)$/;

export interface Playback {
  item_ref: string;
  anchor_server_ms: number;
  position_ms: number;
  rate: number;
  paused: boolean;
}

export interface QueueItem {
  item_ref: string;
}

export interface Member {
  user_id: string;
  name: string;
}

export interface Report {
  activity_id: string | null;
  observed: { offset_ms: number; rtt_ms: number; drift_ms: number; source: string };
  received_ms: number;
}

export interface Peer {
  send(data: string): void;
}

export interface Client {
  peer: Peer;
  /** null until a valid `hello` is received. */
  member: Member | null;
  report: Report | null;
}

export interface Room {
  id: string;
  hostId?: string;
  rev: number;
  seq: number;
  playback: Playback | null;
  queue: QueueItem[];
  clients: Set<Client>;
}

type Obj = Record<string, unknown>;

function isObj(v: unknown): v is Obj {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function isItemRef(v: unknown): v is string {
  return typeof v === 'string' && ITEM_REF.test(v);
}

function isPosition(v: unknown): v is number {
  return typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
}

function isFiniteNum(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}

function log(room: Room, reason: string): void {
  console.error(`[room ${room.id}] ignored: ${reason}`);
}

export function createRoom(id: string): Room {
  return { id, rev: 0, seq: 0, playback: null, queue: [], clients: new Set() };
}

export function positionAt(pb: Playback, now: number): number {
  if (pb.paused) return pb.position_ms;
  return Math.max(0, pb.position_ms + Math.round((now - pb.anchor_server_ms) * pb.rate));
}

function envelope(room: Room, t: string, body: Obj): string {
  return JSON.stringify({ v: 1, t, room: room.id, seq: room.seq, ts: serverNow(), from: 'server', ...body });
}

function broadcast(room: Room, t: string, body: Obj, except?: Client): void {
  const data = envelope(room, t, body);
  for (const c of room.clients) {
    if (c.member && c !== except) c.peer.send(data);
  }
}

export function attach(room: Room, peer: Peer): Client {
  const client: Client = { peer, member: null, report: null };
  room.clients.add(client);
  return client;
}

export function detach(room: Room, client: Client): void {
  room.clients.delete(client);
  if (client.member) broadcast(room, 'presence', { ...client.member, action: 'leave' });
}

export function handleMessage(room: Room, client: Client, raw: string, receivedAt: number): void {
  let msg: unknown;
  try {
    msg = JSON.parse(raw);
  } catch {
    log(room, 'malformed JSON');
    return;
  }
  if (!isObj(msg) || msg.v !== 1 || typeof msg.t !== 'string') {
    log(room, 'not a v1 envelope');
    return;
  }
  if (!client.member) {
    if (msg.t === 'hello') onHello(room, client, msg);
    else log(room, `t=${msg.t.slice(0, 32)} before hello`);
    return;
  }
  switch (msg.t) {
    case 'clock_ping':
      onClockPing(room, client, msg, receivedAt);
      return;
    case 'intent':
      onIntent(room, msg);
      return;
    case 'report':
      onReport(room, client, msg, receivedAt);
      return;
    default:
      log(room, `t=${msg.t.slice(0, 32)}`);
  }
}

function onHello(room: Room, client: Client, msg: Obj): void {
  const info = msg.client;
  if (
    msg.proto !== 1 ||
    !isObj(info) ||
    typeof info.id !== 'string' ||
    info.id === '' ||
    typeof info.name !== 'string' ||
    typeof info.ver !== 'string'
  ) {
    log(room, 'invalid hello');
    return;
  }
  client.member = { user_id: info.id, name: info.name };
  const presence = [...room.clients].flatMap((c) => (c.member ? [c.member] : []));
  const snapshot = { rev: room.rev, playback: room.playback, queue: room.queue, presence };
  client.peer.send(envelope(room, 'welcome', { snapshot, server_now: serverNow() }));
  broadcast(room, 'presence', { ...client.member, action: 'join' }, client);
}

function onClockPing(room: Room, client: Client, msg: Obj, t1: number): void {
  const { ping_id, t0 } = msg;
  if (typeof ping_id !== 'string' || typeof t0 !== 'number' || !Number.isSafeInteger(t0)) {
    log(room, 'invalid clock_ping');
    return;
  }
  client.peer.send(envelope(room, 'clock_pong', { ping_id, t0, t1, t2: serverNow() }));
}

function onIntent(room: Room, msg: Obj): void {
  const { op, args } = msg;
  if (!isObj(args) || !applyIntent(room, op, args, serverNow())) {
    log(room, `intent ${String(op).slice(0, 32)} rejected`);
    return;
  }
  room.rev += 1;
  room.seq += 1;
  broadcast(room, 'state', { rev: room.rev, playback: room.playback, queue: room.queue });
}

/** Mutates room playback/queue. Returns false (and leaves the room untouched) if the intent is not accepted. */
function applyIntent(room: Room, op: unknown, args: Obj, now: number): boolean {
  const pb = room.playback;
  switch (op) {
    case 'play': {
      let itemRef: string;
      if (args.item_ref === undefined) {
        if (!pb) return false;
        itemRef = pb.item_ref;
      } else if (isItemRef(args.item_ref)) {
        itemRef = args.item_ref;
      } else {
        return false;
      }
      const pos = args.position_ms;
      if (pos !== undefined && !isPosition(pos)) return false;
      const resumeAt = pb && pb.item_ref === itemRef ? positionAt(pb, now) : 0;
      room.playback = {
        item_ref: itemRef,
        anchor_server_ms: now,
        position_ms: isPosition(pos) ? pos : resumeAt,
        rate: 1,
        paused: false,
      };
      return true;
    }
    case 'pause':
      if (!pb) return false;
      room.playback = { ...pb, position_ms: positionAt(pb, now), anchor_server_ms: now, paused: true };
      return true;
    case 'seek':
      if (!pb || !isPosition(args.position_ms)) return false;
      room.playback = { ...pb, position_ms: args.position_ms, anchor_server_ms: now };
      return true;
    case 'queue_add':
      if (!isItemRef(args.item_ref)) return false;
      room.queue.push({ item_ref: args.item_ref });
      return true;
    case 'queue_remove': {
      const i = room.queue.findIndex((q) => q.item_ref === args.item_ref);
      if (i < 0) return false;
      room.queue.splice(i, 1);
      return true;
    }
    case 'skip': {
      const head = room.queue.shift();
      if (head) {
        room.playback = { item_ref: head.item_ref, anchor_server_ms: now, position_ms: 0, rate: 1, paused: false };
        return true;
      }
      if (!pb) return false;
      room.playback = null;
      return true;
    }
    default:
      return false;
  }
}

function onReport(room: Room, client: Client, msg: Obj, receivedAt: number): void {
  const o = msg.observed;
  const activityId = msg.activity_id ?? null;
  if (
    !isObj(o) ||
    !isFiniteNum(o.offset_ms) ||
    !isFiniteNum(o.rtt_ms) ||
    !isFiniteNum(o.drift_ms) ||
    typeof o.source !== 'string' ||
    (activityId !== null && typeof activityId !== 'string')
  ) {
    log(room, 'invalid report');
    return;
  }
  client.report = {
    activity_id: activityId,
    observed: { offset_ms: o.offset_ms, rtt_ms: o.rtt_ms, drift_ms: o.drift_ms, source: o.source },
    received_ms: receivedAt,
  };
}
