import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/format.dart';
import 'package:watch_together/room_api.dart';

import 'support.dart';

void main() {
  test('room codes split into two key-cap groups', () {
    expect(codeGroups('k3f9x2qa'), ['k3f9', 'x2qa']);
    expect(codeGroups('ab-cd'), ['ab', 'cd']);
    expect(codeGroups('abc'), ['abc']);
    expect(codeIsUnambiguous('k3f9x2qa'), isTrue);
    expect(codeIsUnambiguous('k0f9'), isFalse);
  });

  test('times, sizes and file-name tails', () {
    expect(fmtTime(0), '0:00');
    expect(fmtTime(724000), '12:04');
    expect(fmtTime(6730000), '1:52:10');
    expect(fmtTimeWords(724000), '12 minutes 4 seconds');
    expect(fmtBytes(1400000000), '1.4 GB');
    expect(fmtBytes(820000000), '820 MB');
    expect(splitTail('movie-night_1080p.mkv'), ('movie-night_', '1080p.mkv'));
    expect(baseName(r'C:\videos\a.mkv'), 'a.mkv');
    expect(baseName('/videos/a.mkv'), 'a.mkv');
  });

  test('GET /rooms/{id} parses both server shapes', () {
    final ts = parseRoomInfo({
      'room_id': roomCode,
      'host_name': 'Mika',
      'member_count': 3,
      'members': [
        {'name': 'Mika'},
        {'name': 'Jo'},
      ],
      'playback': {'item_ref': hostRef, 'position_ms': 724000, 'paused': true},
    })!;
    expect(ts.hostName, 'Mika');
    expect(ts.memberCount, 3);
    expect(ts.memberNames, ['Mika', 'Jo']);
    expect(ts.itemRef, hostRef);
    expect(ts.positionMs, 724000);
    expect(ts.paused, isTrue);

    final rust = parseRoomInfo({
      'room_id': roomCode,
      'members': [
        {'name': 'Jo'},
      ],
    })!;
    expect(rust.hostName, isNull);
    expect(rust.memberCount, 1);
    expect(rust.itemRef, isNull);

    expect(parseRoomInfo({'nope': 1}), isNull);
  });

  test('token expiry is read from the payload', () {
    expect(tokenExpiryMs(token(roomCode, exp: 42)), 42);
    expect(tokenExpiryMs('not-a-token'), isNull);
  });
}
