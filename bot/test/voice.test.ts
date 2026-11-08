import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canCreate, canInvite } from '../src/voice.js';

const channel = { id: 'voice' };
const member = (id: string | null, bot = false) => ({ voice: { channelId: id }, user: { bot } });

test('create requires caller connected to the bound voice channel', () => {
  assert.match(canCreate(member(null), channel)!, /Join/);
  assert.match(canCreate(member('other'), channel)!, /text chat/);
  assert.equal(canCreate(member('voice'), channel), null);
});

test('invite gates caller and target and rejects bots', () => {
  assert.match(canInvite(member(null), member('voice'), channel)!, /Join/);
  assert.match(canInvite(member('other'), member('voice'), channel)!, /text chat/);
  assert.match(canInvite(member('voice'), member(null), channel)!, /join/);
  assert.match(canInvite(member('voice'), member('other'), channel)!, /same/);
  assert.match(canInvite(member('voice'), member('voice', true), channel)!, /Bots/);
  assert.equal(canInvite(member('voice'), member('voice'), channel), null);
});
