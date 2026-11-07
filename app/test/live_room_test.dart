import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/protocol.dart';
import 'package:watch_together/room_client.dart';

/// Talks to a real room server. Skipped unless WT_LIVE=1.
void main() {
  final live = Platform.environment['WT_LIVE'] == '1';
  final server = Uri.parse(
    Platform.environment['WT_SERVER'] ?? 'https://watch.141.253.97.15.sslip.io',
  );

  test(
    'live: create a room, join it, play, and receive state',
    () async {
      final http = HttpClient();
      final request = await http.postUrl(roomsUri(server));
      final response = await request.close();
      expect(response.statusCode, 201);
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
      final room = body['room_id']! as String;
      final token = body['join_token']! as String;

      final welcome = Completer<WelcomeMsg>();
      final state = Completer<StateMsg>();
      final client = RoomClient(
        server: server,
        room: room,
        token: token,
        name: 'flutter-live-test',
        onMessage: (m) {
          final b = m.body;
          if (b is WelcomeMsg && !welcome.isCompleted) welcome.complete(b);
          if (b is StateMsg && !state.isCompleted) state.complete(b);
        },
        onChange: () {},
      );
      client.connect();

      final w = await welcome.future.timeout(const Duration(seconds: 15));
      expect(w.snapshot.rev, greaterThanOrEqualTo(0));
      expect(client.status, ConnectionStatus.joined);

      client.sendIntent('play', {'item_ref': 'yt:abcdefghijk', 'position_ms': 1234});
      final s = await state.future.timeout(const Duration(seconds: 10));
      expect(s.playback, isNotNull);
      expect(s.playback!.itemRef, 'yt:abcdefghijk');
      expect(s.playback!.positionMs, 1234);
      expect(s.playback!.paused, isFalse);
      expect(s.rev, greaterThan(0));

      await client.close();
      http.close();
    },
    skip: live ? false : 'set WT_LIVE=1 to run against a live server',
  );
}
