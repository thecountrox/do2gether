import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRoomApi, RoomApiError, roomUrl } from '../src/roomApi.js';

test('URL building encodes path components and preserves base path', () => {
  assert.equal(roomUrl('https://example.com/api/', 'rooms', 'a/b', 'tokens'),
    'https://example.com/api/rooms/a%2Fb/tokens');
});

test('API routes, auth, methods and response handling', async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    calls.push({ url: String(input), init: init! });
    return new Response(JSON.stringify({ room_id: 'abc', join_token: 'join' }), { status: 200 });
  };
  const api = createRoomApi('https://example.com/', 'secret', fetcher);
  await api.create({ host_id: 'h', host_name: 'Host', guild_id: 'g', voice_channel_id: 'v' });
  await api.token('abc', { user_id: 'u', user_name: 'User' });
  await api.get('abc');
  await api.patch('abc', { locked: true });
  await api.delete('abc');
  await api.stats();
  assert.deepEqual(calls.map(c => [c.init.method, new URL(c.url).pathname]), [
    ['POST', '/rooms'], ['POST', '/rooms/abc/tokens'], ['GET', '/rooms/abc'],
    ['PATCH', '/rooms/abc'], ['DELETE', '/rooms/abc'], ['GET', '/stats'],
  ]);
  assert.ok(calls.every(c => (c.init.headers as Record<string, string>).Authorization === 'Bearer secret'));
  assert.deepEqual(JSON.parse(String(calls[3]?.init.body)), { locked: true });
});

test('maps JSON and empty HTTP errors without leaking credentials', async () => {
  const api = createRoomApi('https://example.com', 'secret', async () =>
    new Response(JSON.stringify({ error: 'room_locked' }), { status: 409 }));
  await assert.rejects(api.token('abc', { user_id: 'u', user_name: 'User' }),
    (error: unknown) => error instanceof RoomApiError && error.status === 409 && error.code === 'room_locked');
  const missing = createRoomApi('https://example.com', 'secret', async () => new Response(null, { status: 404 }));
  await assert.rejects(missing.get('abc'),
    (error: unknown) => error instanceof RoomApiError && error.code === 'http_404');
});

test('delete accepts the server’s empty 204 response', async () => {
  const api = createRoomApi('https://example.com', 'secret', async () => new Response(null, { status: 204 }));
  assert.equal(await api.delete('abc'), undefined);
});
