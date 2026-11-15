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
  }) : title = null,
       isRemote = false;

  /// A copy streamed from the viewer's Jellyfin: [url] is played as-is and never hashed.
  const LocalCopy.remote({
    required String url,
    required this.itemRef,
    required String this.title,
    this.duration,
  }) : path = url,
       bytes = 0,
       isRemote = true;

  /// The file on disk, or the stream URL of a remote copy.
  final String path;
  final int bytes;
  final String itemRef;
  final Duration? duration;
  final bool isRemote;

  /// Display name of a remote copy; a local one shows its file name.
  final String? title;

  String get name => title ?? baseName(path);

  /// `1.4 GB · 24:10` or `Jellyfin · 0:20`, without the duration when it is unknown.
  String get details => [
    isRemote ? 'Jellyfin' : fmtBytes(bytes),
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
