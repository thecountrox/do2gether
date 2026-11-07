import { createHmac, timingSafeEqual } from 'node:crypto';
import { serverNow } from './clock.ts';

export const TOKEN_TTL_MS = 10 * 60 * 1000;

function secret(): string {
  return process.env.WT_SECRET || 'dev-secret';
}

function sign(room: string, exp: number): string {
  return createHmac('sha256', secret()).update(`${room}:${exp}`).digest('base64url');
}

export function signToken(room: string, ttlMs: number = TOKEN_TTL_MS): string {
  const exp = serverNow() + ttlMs;
  const payload = Buffer.from(JSON.stringify({ room, exp })).toString('base64url');
  return `${payload}.${sign(room, exp)}`;
}

export function verifyToken(token: string, roomId: string): boolean {
  const parts = token.split('.');
  if (parts.length !== 2) return false;
  const [payloadPart = '', sigPart = ''] = parts;

  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(payloadPart, 'base64url').toString('utf8'));
  } catch {
    return false;
  }
  if (typeof payload !== 'object' || payload === null) return false;
  const { room, exp } = payload as { room?: unknown; exp?: unknown };
  if (typeof room !== 'string' || typeof exp !== 'number' || !Number.isSafeInteger(exp)) return false;

  // Compare encoded strings, not decoded bytes: base64url decoding is lenient.
  const expected = Buffer.from(sign(room, exp));
  const given = Buffer.from(sigPart);
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return false;

  return room === roomId && exp > serverNow();
}
