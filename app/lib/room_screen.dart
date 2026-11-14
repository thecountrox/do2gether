import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'format.dart';
import 'links.dart';
import 'local_copy.dart';
import 'player.dart';
import 'protocol.dart';
import 'room_client.dart';
import 'room_view.dart';
import 'theme.dart';
import 'widgets/button.dart';

const Duration pollEvery = Duration(seconds: 1);
const Duration reportEvery = Duration(seconds: 5);

/// A pause we sent within this window is credited to "You" when the paused anchor arrives.
const Duration ownPauseWindow = Duration(seconds: 2);

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.server,
    required this.room,
    required this.token,
    required this.name,
    this.clientId,
    this.initialFile,
    this.pickCopy = pickLocalCopy,
  });

  final Uri server;
  final String room;
  final String token;
  final String name;
  final String? clientId;

  /// The copy chosen on Home or in the room-ready dialog; opened on entry.
  final String? initialFile;
  final PickCopy pickCopy;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late RoomClient _client;
  final SyncPlayer _player = SyncPlayer();
  late final Timer _pollTimer;
  late final Timer _reportTimer;
  final List<Member> _members = [];
  List<QueueItem> _queue = [];
  RoomMeta? _meta;
  int _rev = 0;
  Playback? _anchor;
  bool _clockWasReady = false;
  bool _opening = false;
  bool _muted = false;
  bool _fullscreen = false;

  /// Reconnect bookkeeping: RoomClient is one socket, so a drop means a fresh client.
  bool _joinedOnce = false;
  int _retries = 0;
  Timer? _retryTimer;
  String? _gaveUp;

  PauseNotice? _pause;
  int _pauseSerial = 0;
  DateTime? _pauseSentAt;

  /// Names and durations of files we hashed here, so queue rows read as titles.
  final Map<String, ({String name, int? durationMs})> _known = {};

  bool get _joined => _client.status == ConnectionStatus.joined;

  @override
  void initState() {
    super.initState();
    _client = _connect(widget.clientId);
    _pollTimer = Timer.periodic(pollEvery, (_) => _poll());
    _reportTimer = Timer.periodic(reportEvery, (_) => _report());
    final initial = widget.initialFile;
    if (initial != null) _openPath(initial);
  }

  @override
  void dispose() {
    _pollTimer.cancel();
    _reportTimer.cancel();
    _retryTimer?.cancel();
    _client.close();
    _player.dispose();
    if (_fullscreen) defaultExitNativeFullscreen();
    super.dispose();
  }

  RoomClient _connect(String? clientId) => RoomClient(
    server: widget.server,
    room: widget.room,
    token: widget.token,
    name: widget.name,
    clientId: clientId,
    onMessage: _onMessage,
    onChange: _onClientChange,
  )..connect();

  void _onClientChange() {
    // The first completed clock burst makes anchors meaningful: apply the one we hold.
    if (_client.clock.ready && !_clockWasReady) {
      _clockWasReady = true;
      _apply();
    }
    if (_joined) {
      _joinedOnce = true;
      _retries = 0;
    }
    if (_client.status == ConnectionStatus.closed) _scheduleReconnect();
    setState(() {});
  }

  /// Retries with backoff, keeping our client id; a refused token or a gone room is final.
  void _scheduleReconnect() {
    if (_retryTimer?.isActive ?? false) return;
    final reason = _client.closeReason ?? 'connection closed';
    if (reason.contains('4001') || reason.contains('4004')) {
      _gaveUp = reason;
      return;
    }
    final delay = Duration(seconds: math.min(10, 1 << math.min(_retries, 4)));
    _retries++;
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      final id = _client.clientId;
      _client.close();
      setState(() {
        _clockWasReady = false;
        _client = _connect(id);
      });
    });
  }

  void _onMessage(Message message) {
    switch (message.body) {
      case WelcomeMsg(:final snapshot):
        setState(() {
          _rev = snapshot.rev;
          _setAnchor(snapshot.playback);
          _queue = snapshot.queue;
          _meta = snapshot.meta ?? _meta;
          _members
            ..clear()
            ..addAll(snapshot.presence);
        });
        _apply();
      case StateMsg state when state.rev > _rev:
        setState(() {
          _rev = state.rev;
          _setAnchor(state.playback);
          _queue = state.queue;
          _meta = state.meta ?? _meta;
        });
        _apply();
      case PresenceMsg p:
        setState(() {
          _members.removeWhere((m) => m.userId == p.userId);
          if (p.joined) _members.add(Member(userId: p.userId, name: p.name));
        });
      case RejectMsg(:final message):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      default:
        break;
    }
  }

  /// Raises a pause notice on a playing → paused transition; clears it once playback resumes.
  void _setAnchor(Playback? next) {
    final prev = _anchor;
    _anchor = next;
    if (next == null || !next.paused) {
      _pause = null;
      return;
    }
    if (prev == null || prev.paused) return;
    final sent = _pauseSentAt;
    final others = _members.where((m) => m.userId != _client.clientId).toList();
    final String? by;
    if (sent != null && DateTime.now().difference(sent) < ownPauseWindow) {
      by = 'You';
    } else if (others.length == 1) {
      by = others.single.name ?? 'Someone';
    } else {
      by = null;
    }
    _pause = PauseNotice(
      serial: ++_pauseSerial,
      positionMs: next.positionMs,
      by: by,
    );
  }

  Future<void> _apply() async {
    if (!_client.clock.ready) return;
    await _player.apply(_anchor, _client.clock.serverNow());
    if (mounted) setState(() {});
  }

  Future<void> _poll() async {
    if (!_client.clock.ready) return;
    await _player.poll(_anchor, _client.clock.serverNow());
    if (mounted) setState(() {});
  }

  void _report() {
    if (_joined && _client.clock.ready) {
      _client.sendReport(_player.driftMs ?? 0);
    }
  }

  Future<void> _openFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    await _openPath(file.path);
  }

  Future<void> _openPath(String path) async {
    setState(() => _opening = true);
    try {
      await _player.open(path);
      final ref = _player.itemRef;
      if (ref != null) _known[ref] = (name: baseName(path), durationMs: null);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Open failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    await _apply();
  }

  Future<void> _addToQueue() async {
    final copy = await widget.pickCopy();
    if (copy == null || !mounted) return;
    _known[copy.itemRef] = (
      name: copy.name,
      durationMs: copy.duration?.inMilliseconds,
    );
    _client.sendIntent('queue_add', {'item_ref': copy.itemRef});
  }

  void _play() {
    final ref = _player.itemRef;
    _client.sendIntent('play', {'item_ref': ?ref});
  }

  void _pauseRoom() {
    _pauseSentAt = DateTime.now();
    _client.sendIntent('pause');
  }

  int get _roomPositionMs {
    final anchor = _anchor;
    return anchor == null
        ? _player.positionMs
        : positionAt(anchor, _client.clock.serverNow());
  }

  void _seekBy(int deltaMs) => _seekTo(_roomPositionMs + deltaMs);

  void _seekTo(int ms) =>
      _client.sendIntent('seek', {'position_ms': math.max(0, ms)});

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player.player.setVolume(_muted ? 0 : 100);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    await (next ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
  }

  void _showSettings() {
    final drift = _player.driftMs;
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x8C000000),
      builder: (context) => _SettingsDialog(
        rows: [
          ('Server', widget.server.host),
          ('Room', widget.room),
          (
            'Connection',
            _joined
                ? 'Connected · ${_client.clock.rttMs.round()} ms'
                : (_gaveUp ?? 'Reconnecting…'),
          ),
          ('Drift', drift == null ? '—' : '${drift.round()} ms'),
          ('Player', _player.status),
        ],
      ),
    );
  }

  StageMode get _stage {
    final anchor = _anchor;
    final mine = _player.itemRef;
    if (anchor != null && anchor.itemRef != mine) return StageMode.waiting;
    return mine == null ? StageMode.empty : StageMode.video;
  }

  PersonState get _selfState {
    final drift = _player.driftMs;
    if (!_joined) return PersonState.reconnecting;
    if (_player.itemRef == null || _stage == StageMode.waiting) {
      return PersonState.noFile;
    }
    if (_player.player.state.buffering) return PersonState.buffering;
    if (drift != null && drift.abs() >= seekAtMs) return PersonState.drifting;
    return PersonState.synced;
  }

  /// Presence plus ourselves. Peers report drift only to the server, so they read as synced.
  List<RoomPerson> get _people {
    final me = _client.clientId;
    final host = _meta?.hostId;
    final people = [
      for (final m in _members)
        m.userId == me
            ? RoomPerson(
                id: me,
                name: widget.name,
                you: true,
                host: host == me,
                state: _selfState,
                driftMs: _player.driftMs ?? 0,
              )
            : RoomPerson(
                id: m.userId,
                name: m.name ?? 'Guest',
                host: host == m.userId,
              ),
    ];
    if (!people.any((p) => p.you)) {
      people.insert(
        0,
        RoomPerson(
          id: me,
          name: widget.name,
          you: true,
          host: host == me,
          state: _selfState,
          driftMs: _player.driftMs ?? 0,
        ),
      );
    }
    return [...people.where((p) => p.host), ...people.where((p) => !p.host)];
  }

  QueueRow _row(String ref, {String? title, int? durationMs}) {
    final known = _known[ref];
    final parts = ref.split(':');
    final duration =
        durationMs ??
        known?.durationMs ??
        (ref == _player.itemRef
            ? _player.player.state.duration.inMilliseconds
            : null);
    final bytes = parts.length > 2 ? int.tryParse(parts[2]) : null;
    return (
      title:
          title ??
          known?.name ??
          'File ${parts.length > 3 ? parts[3].substring(0, 6) : ref}',
      detail: duration != null && duration > 0
          ? fmtTime(duration)
          : (bytes == null ? '' : fmtBytes(bytes)),
    );
  }

  String get _title {
    final meta = _meta;
    if (meta == null) return 'Room';
    return meta.hostId == _client.clientId
        ? 'Your room'
        : "${meta.hostName}'s room";
  }

  RoomViewData get _data {
    final state = _player.player.state;
    final anchor = _anchor;
    final path = _player.path;
    return RoomViewData(
      room: widget.room,
      title: _title,
      invite: inviteUrl(widget.server, widget.token),
      connected: _joined,
      connecting: !_joinedOnce,
      disconnectReason: _gaveUp,
      people: _people,
      nowPlaying: anchor == null ? null : _row(anchor.itemRef),
      upNext: [
        for (final q in _queue)
          _row(q.itemRef, title: q.title, durationMs: q.durationMs),
      ],
      stage: _stage,
      mismatch: _player.itemRef != null,
      opening: _opening,
      fileName: path == null ? null : baseName(path),
      positionMs: _player.itemRef == null ? 0 : _roomPositionMs,
      durationMs: state.duration.inMilliseconds,
      bufferedMs: state.buffer.inMilliseconds,
      playing: anchor != null && !anchor.paused,
      aspect: (state.width ?? 0) > 0 && (state.height ?? 0) > 0
          ? state.width! / state.height!
          : 16 / 9,
      muted: _muted,
      fullscreen: _fullscreen,
      pause: _pause,
    );
  }

  @override
  Widget build(BuildContext context) => WtScaffold(
    child: RoomView(
      data: _data,
      video: Video(
        controller: _player.video,
        controls: NoVideoControls,
        fill: WtColors.board,
        pauseUponEnteringBackgroundMode: false,
      ),
      onBack: () => Navigator.of(context).pop(),
      onOpenFile: _openFile,
      onPlay: _play,
      onPause: _pauseRoom,
      onSeekBy: _seekBy,
      onSeekTo: _seekTo,
      onToggleMute: _toggleMute,
      onFullscreen: _toggleFullscreen,
      onSettings: _showSettings,
      onAddToQueue: _addToQueue,
    ),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: WtColors.plum2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(WtRadius.surface),
      side: const BorderSide(color: WtColors.line, width: 2),
    ),
    child: SizedBox(
      width: 440,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Room settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: WtColors.tx3,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        value,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: WtColors.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: WtButton(
                label: 'Done',
                style: WtButtonStyle.ghost,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
