import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/player.dart';
import 'package:watch_together/protocol.dart';

const t = 1762500000000;

Playback pb(int positionMs, int anchor, double rate, bool paused) => Playback(
  itemRef: 'yt:dQw4w9WgXcQ',
  anchorServerMs: anchor,
  positionMs: positionMs,
  rate: rate,
  paused: paused,
);

void main() {
  group('positionAt', () {
    test('playing advances with server time', () {
      expect(positionAt(pb(42000, t, 1, false), t), 42000);
      expect(positionAt(pb(42000, t, 1, false), t + 2500), 44500);
    });

    test('paused holds the anchor position whatever the time', () {
      expect(positionAt(pb(42000, t, 1, true), t + 60000), 42000);
      expect(positionAt(pb(42000, t, 1, true), t - 60000), 42000);
    });

    test('rate scales elapsed time', () {
      expect(positionAt(pb(10000, t, 1.5, false), t + 2000), 13000);
      expect(positionAt(pb(10000, t, 0.25, false), t + 1000), 10250);
    });

    test('negative elapsed extrapolates backwards, never before 0', () {
      expect(positionAt(pb(42000, t, 1, false), t - 300), 41700);
      expect(positionAt(pb(42000, t, 2, false), t - 300), 41400);
      expect(positionAt(pb(100, t, 1, false), t - 300), 0);
    });

    test('rounds like JS Math.round', () {
      expect(positionAt(pb(10, 0, 1.5, false), 1), 12); // 11.5 -> 12
      expect(positionAt(pb(10, 1, 0.5, false), 0), 10); // 9.5 -> 10
      expect(positionAt(pb(10, 1, 1.5, false), 0), 9); // 8.5 -> 9
    });
  });

  group('item_ref of a local file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wt-player-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('small file: size + the whole-file hash twice', () async {
      final f = File('${dir.path}/small.bin')..writeAsStringSync('hello world');
      const h = 'b94d27b9934d3e08a52e52d7da7dabfa'; // sha256("hello world")[:32]
      final ref = await itemRefForFile(f.path);
      expect(ref, 'file:sha256p:11:$h:$h');
      expect(isItemRef(ref), isTrue);
    });

    test('empty file matches the Rust client', () {
      final f = File('${dir.path}/empty.bin')..writeAsBytesSync([]);
      const h = 'e3b0c44298fc1c149afbf4c8996fb924';
      expect(itemRefForFileSync(f.path), 'file:sha256p:0:$h:$h');
    });

    test('large file: first and last 4 MiB, each byte range seen', () {
      final size = 2 * hashChunkBytes + 10;
      final data = List<int>.filled(size, 0);
      for (var i = 0; i < size; i += 4096) {
        data[i] = i ~/ 4096 % 251;
      }
      final f = File('${dir.path}/big.bin')..writeAsBytesSync(data);
      String hex(List<int> b) => sha256.convert(b).toString().substring(0, 32);
      final head = hex(data.sublist(0, hashChunkBytes));
      final tail = hex(data.sublist(size - hashChunkBytes));
      final a = itemRefForFileSync(f.path);
      expect(a, 'file:sha256p:$size:$head:$tail');
      expect(isItemRef(a), isTrue);

      data[size - 1] = 1;
      f.writeAsBytesSync(data);
      final b = itemRefForFileSync(f.path);
      expect(b.split(':')[3], a.split(':')[3], reason: 'head unchanged');
      expect(b.split(':')[4], isNot(a.split(':')[4]), reason: 'tail sees the last byte');
    });
  });

  test('drift policy bands', () {
    const table = [
      (0.0, Correction.none),
      (249.0, Correction.none),
      (-249.0, Correction.none),
      (250.0, Correction.slowDown),
      (1999.0, Correction.slowDown),
      (-250.0, Correction.speedUp),
      (-1999.0, Correction.speedUp),
      (2000.0, Correction.seek),
      (-2000.0, Correction.seek),
      (-90000.0, Correction.seek),
    ];
    for (final (drift, expected) in table) {
      expect(decideCorrection(drift), expected, reason: 'drift $drift');
    }
  });
}
