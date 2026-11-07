import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/protocol.dart';
import 'package:watch_together/room_client.dart';

const film = 'file:sha256p:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const env = Envelope(room: 'k3x9a0qz', seq: 7, ts: 1762500000000, from: 'flutter-01', id: 'i7');
const pb = Playback(
  itemRef: film,
  anchorServerMs: 1762500000000,
  positionMs: 42000,
  rate: 1.25,
  paused: false,
);

void main() {
  group('envelope', () {
    test('every message type roundtrips through encode/decode', () {
      final bodies = <Body>[
        const HelloMsg(clientId: 'flutter-01', name: 'ann', ver: '1.0.0'),
        const WelcomeMsg(
          snapshot: Snapshot(
            rev: 3,
            playback: pb,
            queue: [QueueItem(itemRef: 'yt:dQw4w9WgXcQ', title: 't', durationMs: 5, addedBy: 'a')],
            presence: [Member(userId: 'a', name: 'ann', caps: ['player:mpv'])],
            meta: RoomMeta(hostId: 'a', hostName: 'ann', controls: 'host', locked: false),
          ),
          serverNow: 1762500000123,
        ),
        const ClockPingMsg(pingId: 'p0', t0: 1),
        const ClockPongMsg(pingId: 'p0', t0: 1, t1: 2, t2: 3),
        const IntentMsg(op: 'seek', args: {'position_ms': 52000}),
        const StateMsg(rev: 4, playback: null, queue: [], meta: RoomMeta(hostId: 'a', hostName: 'ann', controls: 'all', locked: true)),
        const ReportMsg(
          activityId: null,
          observed: Observed(offsetMs: 0.5, rttMs: 12, driftMs: -3, source: 'flutter'),
        ),
        const PresenceMsg(userId: 'b', name: 'bob', joined: false),
        const EventMsg(kind: 'x', data: {'k': 1}),
        const RejectMsg(code: 'intent_rejected', message: 'nothing is playing', reqId: 'i7'),
      ];
      expect(bodies.map((b) => b.type).toSet(), hasLength(10));
      for (final body in bodies) {
        final raw = encodeMessage(env, body);
        final decoded = decodeMessage(raw);
        expect(decoded, isNotNull, reason: raw);
        expect(decoded!.body.type, body.type);
        expect(decoded.envelope.room, env.room);
        expect(decoded.envelope.seq, env.seq);
        expect(decoded.envelope.ts, env.ts);
        expect(decoded.envelope.from, env.from);
        expect(decoded.envelope.id, env.id);
        expect(encodeMessage(decoded.envelope, decoded.body), raw, reason: 'stable re-encode');
      }
    });

    test('encodes the schema envelope with id only when present', () {
      final json = jsonDecode(encodeMessage(
        const Envelope(room: 'r', seq: 0, ts: 5, from: 'me'),
        const HelloMsg(clientId: 'me', name: 'ann', ver: '1.0.0'),
      )) as Map<String, Object?>;
      expect(json, {
        'v': 1,
        't': 'hello',
        'room': 'r',
        'seq': 0,
        'ts': 5,
        'from': 'me',
        'proto': 1,
        'client': {'id': 'me', 'name': 'ann', 'ver': '1.0.0'},
        'caps': <Object?>[],
      });
    });

    test('decodes a server state and its anchor', () {
      const raw = '{"v":1,"t":"state","room":"r","seq":3,"ts":5,"from":"server","rev":2,'
          '"playback":{"item_ref":"yt:dQw4w9WgXcQ","anchor_server_ms":10,"position_ms":42000,'
          '"rate":1,"paused":false},"queue":[]}';
      final body = decodeMessage(raw)!.body as StateMsg;
      expect(body.rev, 2);
      expect(body.playback!.rate, 1.0);
      expect(positionAt(body.playback!, 1010), 43000);
    });

    test('meta is optional for old welcomes and validated when present', () {
      const old = WelcomeMsg(snapshot: Snapshot(rev: 0, playback: null, queue: [], presence: []), serverNow: 1);
      expect((decodeMessage(encodeMessage(env, old))!.body as WelcomeMsg).snapshot.meta, isNull);
      final json = jsonDecode(encodeMessage(env, old)) as Map<String, dynamic>;
      (json['snapshot'] as Map<String, dynamic>)['meta'] = {'host_id': 'a', 'host_name': 'Ann', 'controls': 'all', 'locked': true};
      final meta = (decodeMessage(jsonEncode(json))!.body as WelcomeMsg).snapshot.meta!;
      expect([meta.hostId, meta.hostName, meta.controls, meta.locked], ['a', 'Ann', 'all', true]);
      (json['snapshot'] as Map<String, dynamic>)['meta']['controls'] = 'everyone';
      expect(decodeMessage(jsonEncode(json)), isNull);
    });

    test('host intents are recognized', () {
      for (final (op, args) in [('set_controls', {'controls': 'all'}), ('lock', {'locked': true}), ('kick', {'user_id': 'b'})]) {
        expect((decodeMessage(encodeMessage(env, IntentMsg(op: op, args: args)))!.body as IntentMsg).op, op);
      }
    });
  });

  group('ignored input', () {
    test('unknown type is ignored', () {
      expect(decodeMessage('{"v":1,"t":"chat","room":"r","seq":1,"ts":5,"from":"s","text":"hi"}'),
          isNull);
    });

    test('invalid messages are ignored, never thrown', () {
      final bad = [
        '',
        '{nope',
        '[]',
        'null',
        '42',
        '{"v":2,"t":"reject","room":"r","seq":1,"ts":5,"from":"s","code":"c","message":"m"}',
        '{"t":"reject","room":"r","seq":1,"ts":5,"from":"s","code":"c","message":"m"}',
        '{"v":1,"t":"reject","room":"","seq":1,"ts":5,"from":"s","code":"c","message":"m"}',
        '{"v":1,"t":"reject","room":"r","seq":-1,"ts":5,"from":"s","code":"c","message":"m"}',
        '{"v":1,"t":"reject","room":"r","seq":1.5,"ts":5,"from":"s","code":"c","message":"m"}',
        '{"v":1,"t":"reject","room":"r","seq":1,"ts":5,"from":"s","code":"c"}',
        '{"v":1,"t":"reject","room":"r","seq":1,"ts":5,"from":"s","id":7,"code":"c","message":"m"}',
        '{"v":1,"t":"state","room":"r","seq":1,"ts":5,"from":"s","rev":1,"queue":[]}',
        '{"v":1,"t":"state","room":"r","seq":1,"ts":5,"from":"s","rev":1,"queue":[],'
            '"playback":{"item_ref":"nope","anchor_server_ms":0,"position_ms":0,"rate":1,"paused":false}}',
        '{"v":1,"t":"state","room":"r","seq":1,"ts":5,"from":"s","rev":1,"queue":[],'
            '"playback":{"item_ref":"yt:dQw4w9WgXcQ","anchor_server_ms":0,"position_ms":0,"rate":9,"paused":false}}',
        '{"v":1,"t":"presence","room":"r","seq":1,"ts":5,"from":"s","user_id":"u","action":"wave"}',
        '{"v":1,"t":"intent","room":"r","seq":1,"ts":5,"from":"s","op":"rewind","args":{}}',
        '{"v":1,"t":"welcome","room":"r","seq":1,"ts":5,"from":"s","server_now":5,'
            '"snapshot":{"rev":0,"playback":null,"queue":[],"presence":[{"name":"no id"}]}}',
      ];
      for (final raw in bad) {
        expect(decodeMessage(raw), isNull, reason: raw);
      }
    });

    test('integral floats count as integers, like JSON Schema', () {
      final m = decodeMessage('{"v":1,"t":"clock_pong","room":"r","seq":1.0,"ts":5,"from":"s",'
          '"ping_id":"p0","t0":1,"t1":2.0,"t2":3}');
      expect((m!.body as ClockPongMsg).t1, 2);
    });
  });

  group('item_ref grammar', () {
    test('accepts the four prefixes', () {
      for (final ok in [
        film,
        'file:sha256p:0:e3b0c44298fc1c149afbf4c8996fb924:e3b0c44298fc1c149afbf4c8996fb924',
        'yt:dQw4w9WgXcQ',
        'ytm:A-b_C1d2E3f',
        'subsonic:navi-1/tr_42-x',
      ]) {
        expect(isItemRef(ok), isTrue, reason: ok);
      }
    });

    test('rejects everything else', () {
      for (final bad in [
        '',
        'file:sha256p::aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'file:sha256p:-1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'file:sha256p:1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'file:sha256p:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'file:sha256p:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:c',
        'file:sha1:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'yt:dQw4w9WgXc',
        'yt:dQw4w9WgXcQQ',
        'yt:dQw4w9WgX.Q',
        'ytm:',
        'subsonic:Navi/1',
        'subsonic:navi/',
        'subsonic:/1',
        'subsonic:navi/a/b',
        'spotify:track:1',
        'yt:dQw4w9WgXcQ\n',
        ' yt:dQw4w9WgXcQ',
      ]) {
        expect(isItemRef(bad), isFalse, reason: bad);
      }
    });
  });

  group('endpoints', () {
    test('ws and rooms URLs keep host, port and path', () {
      final https = Uri.parse('https://watch.example/');
      expect(wsUri(https, 'r1', 't/+=').toString(), 'wss://watch.example/ws?room=r1&token=t%2F%2B%3D');
      expect(roomsUri(https).toString(), 'https://watch.example/rooms');
      final http = Uri.parse('http://127.0.0.1:8787/wt');
      expect(wsUri(http, 'r1', 't').toString(), 'ws://127.0.0.1:8787/wt/ws?room=r1&token=t');
      expect(roomsUri(http).toString(), 'http://127.0.0.1:8787/wt/rooms');
    });
  });
}
