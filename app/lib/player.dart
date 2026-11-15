/// The local media_kit player and how it follows the room's playback anchor.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'protocol.dart';

const int hashChunkBytes = 4 * 1024 * 1024;

/// Drift policy (docs/00-spec.md, Sync rules): below [deadBandMs] leave it, up to [seekAtMs]
/// nudge the rate by [nudge] for up to [nudgeFor], beyond that seek.
const int deadBandMs = 250;
const int seekAtMs = 2000;
const double nudge = 0.03;
const Duration nudgeFor = Duration(seconds: 2);

/// `file:sha256p:<size>:<first32hex>:<last32hex>`, hashed off the UI isolate.
Future<String> itemRefForFile(String path) => Isolate.run(() => itemRefForFileSync(path));

/// SHA-256 of the first 4 MiB and of the last 4 MiB, each truncated to 32 lowercase hex digits.
/// Files under 8 MiB hash the whole file, twice.
String itemRefForFileSync(String path) {
  final f = File(path).openSync();
  try {
    final size = f.lengthSync();
    if (size < 2 * hashChunkBytes) {
      final whole = _hex32(_read(f, 0, size));
      return 'file:sha256p:$size:$whole:$whole';
    }
    final head = _hex32(_read(f, 0, hashChunkBytes));
    final tail = _hex32(_read(f, size - hashChunkBytes, hashChunkBytes));
    return 'file:sha256p:$size:$head:$tail';
  } finally {
    f.closeSync();
  }
}

Uint8List _read(RandomAccessFile f, int start, int length) {
  f.setPositionSync(start);
  final out = BytesBuilder(copy: false);
  while (out.length < length) {
    final chunk = f.readSync(length - out.length);
    if (chunk.isEmpty) break;
    out.add(chunk);
  }
  return out.takeBytes();
}

String _hex32(List<int> bytes) => sha256.convert(bytes).toString().substring(0, 32);

enum Correction { none, speedUp, slowDown, seek }

/// [driftMs] is player position minus room position. Half-open bands: 250 nudges, 2000 seeks.
Correction decideCorrection(double driftMs) {
  final d = driftMs.abs();
  if (d < deadBandMs) return Correction.none;
  if (d < seekAtMs) return driftMs < 0 ? Correction.speedUp : Correction.slowDown;
  return Correction.seek;
}

class SyncPlayer {
  SyncPlayer() : player = Player() {
    video = VideoController(player);
  }

  final Player player;
  late final VideoController video;

  /// The open local file; null for a remote source.
  String? path;

  /// The ref of what is open: hashed from the local file, or given with the remote source.
  String? itemRef;

  /// Player position minus room position at the last check; null when not comparable.
  double? driftMs;

  /// What the last check did, for display.
  String status = 'no local file';

  Timer? _nudgeTimer;
  Future<void> _queue = Future.value();

  int get positionMs => player.state.position.inMilliseconds;

  /// Hashes and opens [file] paused. The caller applies the current anchor afterwards.
  Future<void> open(String file) async {
    final ref = await itemRefForFile(file);
    await player.open(Media(file), play: false);
    path = file;
    itemRef = ref;
    status = 'opened';
  }

  /// Opens a stream that is not on disk (a Jellyfin URL) paused, under the ref it was picked as:
  /// there is no file to hash. The caller applies the current anchor afterwards.
  Future<void> openSource({
    required String uri,
    required String itemRef,
  }) async {
    await player.open(Media(uri), play: false);
    path = null;
    this.itemRef = itemRef;
    status = 'opened';
  }

  /// A new anchor arrived: a paused anchor always pauses and seeks; a playing one goes through
  /// the drift policy.
  Future<void> apply(Playback? pb, int serverNowMs) =>
      _serial(() => _follow(pb, serverNowMs, fresh: true));

  /// The 1 s check: measure drift and correct; a paused anchor only re-seeks when off.
  Future<void> poll(Playback? pb, int serverNowMs) =>
      _serial(() => _follow(pb, serverNowMs, fresh: false));

  Future<void> dispose() async {
    _nudgeTimer?.cancel();
    await player.dispose();
  }

  /// Player calls never overlap: a state apply and a poll would otherwise race seeks.
  Future<void> _serial(Future<void> Function() step) {
    return _queue = _queue.then((_) => step()).catchError((Object e) {
      status = 'player error: $e';
    });
  }

  Future<void> _follow(Playback? pb, int nowMs, {required bool fresh}) async {
    if (itemRef == null) {
      driftMs = null;
      status = 'no local file';
      return;
    }
    if (pb == null) {
      driftMs = null;
      status = 'room is idle';
      await _endNudge(1);
      if (player.state.playing) await player.pause();
      return;
    }
    if (pb.itemRef != itemRef) {
      driftMs = null;
      status = 'waiting for host file';
      return;
    }
    if (pb.paused) {
      await _endNudge(pb.rate);
      if (player.state.playing) await player.pause();
      final drift = (positionMs - pb.positionMs).toDouble();
      driftMs = drift;
      if (fresh || drift.abs() >= deadBandMs) {
        await player.seek(Duration(milliseconds: pb.positionMs));
      }
      status = 'paused';
      return;
    }
    final target = positionAt(pb, nowMs);
    final drift = (positionMs - target).toDouble();
    driftMs = drift;
    switch (decideCorrection(drift)) {
      case Correction.none:
        await _endNudge(pb.rate);
        status = 'in sync';
      case Correction.speedUp || Correction.slowDown when _nudgeTimer != null:
        status = 'nudging';
      case Correction.speedUp || Correction.slowDown:
        final speed = pb.rate * (drift < 0 ? 1 + nudge : 1 - nudge);
        await player.setRate(speed);
        _nudgeTimer = Timer(nudgeFor, () {
          _nudgeTimer = null;
          _serial(() => player.setRate(pb.rate));
        });
        status = 'nudging ×${speed.toStringAsFixed(2)}';
      case Correction.seek:
        await _endNudge(pb.rate);
        await player.seek(Duration(milliseconds: target));
        status = 'seeked';
    }
    if (!player.state.playing) await player.play();
  }

  /// Cancels any nudge and makes sure the player runs at [rate].
  Future<void> _endNudge(double rate) async {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    if (player.state.rate != rate) await player.setRate(rate);
  }
}
