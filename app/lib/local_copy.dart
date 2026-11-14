/// The viewer's own copy of the video, picked before or inside a room.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:media_kit/media_kit.dart';

import 'format.dart';
import 'player.dart';

class LocalCopy {
  const LocalCopy({
    required this.path,
    required this.bytes,
    required this.itemRef,
    this.duration,
  });
  final String path;
  final int bytes;
  final String itemRef;
  final Duration? duration;

  String get name => baseName(path);

  /// `1.4 GB · 24:10`, without the duration when it is unknown.
  String get details => [
    fmtBytes(bytes),
    if (duration case final d? when d > Duration.zero) fmtTime(d.inMilliseconds),
  ].join(' · ');
}

typedef PickCopy = Future<LocalCopy?> Function();

/// Asks for a file, hashes it the same way [SyncPlayer.open] does and probes its duration.
Future<LocalCopy?> pickLocalCopy() async {
  final file = await openFile();
  if (file == null) return null;
  final ref = await itemRefForFile(file.path);
  final bytes = await File(file.path).length();
  return LocalCopy(
    path: file.path,
    bytes: bytes,
    itemRef: ref,
    duration: await _probeDuration(file.path),
  );
}

Future<Duration?> _probeDuration(String path) async {
  final player = Player();
  try {
    await player.open(Media(path), play: false);
    if (player.state.duration > Duration.zero) return player.state.duration;
    return await player.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(const Duration(seconds: 4));
  } on Object {
    return null;
  } finally {
    await player.dispose();
  }
}
