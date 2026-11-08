import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardButtons, roomEmbed, statusEmbed } from '../src/card.js';
import type { Room } from '../src/roomApi.js';

const room: Room = { room_id: 'abc', host_id: 'h', host_name: 'Host', members: [], rev: 2,
  playback: null, controls: 'host', locked: false };

test('card formats members and fallback playback', () => {
  const fields = roomEmbed(room, undefined, 'Voice').toJSON().fields!;
  assert.equal(fields.find(f => f.name === 'members')?.value, '0/50');
  assert.equal(fields.find(f => f.name === 'now playing')?.value, 'nothing yet');
  const playing = roomEmbed({ ...room, members: [{ user_id: 'h', name: 'Host' }],
    playback: { item_ref: 'movie', position_ms: 0, paused: false } }, undefined, 'Voice').toJSON().fields!;
  assert.equal(playing.find(f => f.name === 'members')?.value, '1/50');
  assert.equal(playing.find(f => f.name === 'now playing')?.value, 'movie');
});

test('close is only visible to the host; status shows drift and controls', () => {
  assert.equal(cardButtons('abc', false).components.length, 1);
  assert.equal(cardButtons('abc', true).components.length, 2);
  const fields = statusEmbed(room, { room_id: 'abc', rev: 2, members: 0,
    p50_drift_ms: 3.2, p95_drift_ms: 8.7, corrections: 0 }, 'Voice').toJSON().fields!;
  assert.equal(fields.find(f => f.name === 'drift p95')?.value, '9 ms');
  assert.equal(fields.find(f => f.name === 'drift p50')?.value, '3 ms');
  assert.equal(fields.find(f => f.name === 'locked / controls')?.value, 'no / host');
});
