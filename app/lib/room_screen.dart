import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player.dart';
import 'protocol.dart';
import 'room_client.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/identity.dart';
import 'widgets/sparkles.dart';

const Duration pollEvery = Duration(seconds: 1);
const Duration reportEvery = Duration(seconds: 5);
const int seekStepMs = 10000;

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.server,
    required this.room,
    required this.token,
    required this.name,
    this.clientId,
  });

  final Uri server;
  final String room;
  final String token;
  final String name;
  final String? clientId;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final RoomClient _client;
  final SyncPlayer _player = SyncPlayer();
  late final Timer _pollTimer;
  late final Timer _reportTimer;
  final List<Member> _members = [];
  List<QueueItem> _queue = [];
  int _rev = 0;
  Playback? _anchor;
  bool _clockWasReady = false;
  bool _opening = false;
  bool _copied = false;
  bool _muted = false;
  Timer? _copyTimer;

  bool get _joined => _client.status == ConnectionStatus.joined;

  @override
  void initState() {
    super.initState();
    _client = RoomClient(
      server: widget.server,
      room: widget.room,
      token: widget.token,
      name: widget.name,
      clientId: widget.clientId,
      onMessage: _onMessage,
      onChange: _onClientChange,
    )..connect();
    _pollTimer = Timer.periodic(pollEvery, (_) => _poll());
    _reportTimer = Timer.periodic(reportEvery, (_) => _report());
  }

  @override
  void dispose() {
    _pollTimer.cancel();
    _reportTimer.cancel();
    _copyTimer?.cancel();
    _client.close();
    _player.dispose();
    super.dispose();
  }

  void _onClientChange() {
    // The first completed clock burst makes anchors meaningful: apply the one we hold.
    if (_client.clock.ready && !_clockWasReady) {
      _clockWasReady = true;
      _apply();
    }
    setState(() {});
  }

  void _onMessage(Message message) {
    switch (message.body) {
      case WelcomeMsg(:final snapshot):
        setState(() {
          _rev = snapshot.rev;
          _anchor = snapshot.playback;
          _queue = snapshot.queue;
          _members
            ..clear()
            ..addAll(snapshot.presence);
        });
        _apply();
      case StateMsg state when state.rev > _rev:
        setState(() {
          _rev = state.rev;
          _anchor = state.playback;
          _queue = state.queue;
        });
        _apply();
      case PresenceMsg p:
        setState(() {
          _members.removeWhere((m) => m.userId == p.userId);
          if (p.joined) _members.add(Member(userId: p.userId, name: p.name));
        });
      case RejectMsg(:final message):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      default:
        break;
    }
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
    setState(() => _opening = true);
    try {
      await _player.open(file.path);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Open failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    await _apply();
  }

  void _play() {
    final ref = _player.itemRef;
    _client.sendIntent('play', {'item_ref': ?ref});
  }

  void _pause() => _client.sendIntent('pause');

  void _seekBy(int deltaMs) {
    final anchor = _anchor;
    final now = anchor == null
        ? _player.positionMs
        : positionAt(anchor, _client.clock.serverNow());
    _client.sendIntent('seek', {'position_ms': math.max(0, now + deltaMs)});
  }

  String get _matchState {
    final anchor = _anchor;
    if (_player.itemRef == null) return 'no local file';
    if (anchor == null) return 'room is idle';
    return anchor.itemRef == _player.itemRef
        ? 'local file matches'
        : 'waiting for host file';
  }

  void _copyRoom() {
    Clipboard.setData(ClipboardData(text: widget.room));
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player.player.setVolume(_muted ? 0 : 100);
  }

  @override
  Widget build(BuildContext context) {
    return WtScaffold(
      child: WtBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            return Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: WtSparkles(seed: widget.room)),
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            wide ? 24 : 12,
                            72,
                            wide ? 24 : 12,
                            88,
                          ),
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: WtColors.bg,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: WtColors.highlight,
                                      width: 2,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(22),
                                    child: _videoArea(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: _topRow(wide),
                      ),
                      if (!_joined)
                        Positioned(
                          top: 64,
                          left: 16,
                          right: 16,
                          child: const WtBanner(
                            message: 'Reconnecting…',
                            color: WtColors.warn,
                          ),
                        ),
                      Positioned(
                        bottom: 16,
                        left: 16,
                        right: 16,
                        child: Center(child: _controls()),
                      ),
                    ],
                  ),
                ),
                if (wide)
                  Container(
                    width: 320,
                    decoration: const BoxDecoration(
                      color: WtColors.surface,
                      border: Border(
                        left: BorderSide(color: WtColors.stroke, width: 2),
                      ),
                    ),
                    child: _sidebar(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topRow(bool wide) {
    final drift = _player.driftMs?.abs();
    final synced = _joined && _client.clock.ready && drift != null;
    final color = !_joined || (synced && drift >= 400)
        ? WtColors.danger
        : synced && drift < 80
        ? WtColors.live
        : WtColors.warn;
    final label = !_joined
        ? 'off'
        : !synced
        ? 'syncing'
        : drift < 80
        ? '${drift.round()} ms · in sync'
        : drift < 400
        ? '${drift.round()} ms · syncing'
        : 'off';
    return Row(
      children: [
        _iconButton(
          Icons.chevron_left,
          'Back',
          () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 6),
        WtChip(
          label: _copied ? 'copied' : widget.room,
          onTap: _copyRoom,
          icon: Icons.copy_outlined,
          tilt: 0.018,
        ),
        const Spacer(),
        WtChip(label: label, color: color, icon: null, tilt: -0.014),
        const SizedBox(width: 8),
        WtSyncDot(color: color, connected: _joined),
        const SizedBox(width: 12),
        if (wide)
          WtAvatarStack(members: _members)
        else
          _iconButton(
            Icons.people_outline,
            'People',
            () => WtSheet.show<void>(
              context,
              title: 'In this room',
              child: _roomSections(),
            ),
          ),
      ],
    );
  }

  Widget _iconButton(
    IconData icon,
    String tooltip,
    VoidCallback? action, {
    bool compact = false,
  }) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: action,
      icon: Icon(icon),
      iconSize: compact ? 20 : 24,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 36, height: 36)
          : null,
      padding: compact ? EdgeInsets.zero : null,
      color: WtColors.text,
      style: IconButton.styleFrom(
        backgroundColor: WtColors.surface,
        disabledForegroundColor: WtColors.muted,
      ),
    ),
  );

  Widget _videoArea() {
    final empty =
        _player.itemRef == null || _matchState == 'waiting for host file';
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: _player.video,
          controls: NoVideoControls,
          pauseUponEnteringBackgroundMode: false,
        ),
        if (empty) ...[
          const ColoredBox(color: WtColors.surface),
          const Positioned.fill(child: WtSparkles()),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color(0x002A1A4A), Color(0xB0170F2B)],
                ),
              ),
            ),
          ),
        ],
        if (empty)
          Center(
            child: _anchor != null && _matchState != 'local file matches'
                ? WtEmptyState(
                    icon: Icons.hourglass_top,
                    message: "Waiting for the host's file",
                    outlined: true,
                    action: WtButton(
                      label: 'Open file',
                      icon: Icons.folder_open,
                      onPressed: _opening ? null : _openFile,
                    ),
                  )
                : WtEmptyState(
                    icon: Icons.movie_outlined,
                    message: _opening
                        ? 'Hashing file…'
                        : 'Open a file to watch together',
                    action: WtButton(
                      label: 'Open file',
                      icon: Icons.folder_open,
                      onPressed: _opening ? null : _openFile,
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _controls() {
    final enabled =
        _joined &&
        _player.itemRef != null &&
        _matchState != 'waiting for host file';
    final playing = _anchor != null && !_anchor!.paused;
    final current = _anchor == null
        ? _player.positionMs
        : positionAt(_anchor!, _client.clock.serverNow());
    final total = _player.player.state.duration.inMilliseconds;
    return WtGlassBar(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [WtColors.pink, WtColors.violet],
              ),
            ),
            child: IconButton(
              tooltip: playing ? 'Pause' : 'Play',
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              iconSize: 22,
              padding: EdgeInsets.zero,
              color: WtColors.bg,
              disabledColor: WtColors.bg.withValues(alpha: 0.4),
              onPressed: enabled ? (playing ? _pause : _play) : null,
            ),
          ),
          _iconButton(
            Icons.replay_10,
            'Back 10 seconds',
            enabled ? () => _seekBy(-seekStepMs) : null,
            compact: true,
          ),
          _iconButton(
            Icons.forward_10,
            'Forward 10 seconds',
            enabled ? () => _seekBy(seekStepMs) : null,
            compact: true,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${_fmt(current)} / ${_fmt(total)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: enabled
                    ? WtColors.muted
                    : WtColors.muted.withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _iconButton(
            _muted ? Icons.volume_off : Icons.volume_up,
            _muted ? 'Unmute' : 'Mute',
            enabled ? _toggleMute : null,
            compact: true,
          ),
          _iconButton(
            Icons.fullscreen,
            'Fullscreen unavailable',
            null,
            compact: true,
          ),
        ],
      ),
    );
  }

  Widget _sidebar() =>
      ListView(padding: const EdgeInsets.all(24), children: [_roomSections()]);

  Widget _roomSections() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('In this room', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      for (final m in _members)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              WtAvatar(id: m.userId, name: m.name ?? m.userId),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  m.name ?? m.userId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (m.userId == _client.clientId) ...[
                const SizedBox(width: 8),
                const WtChip(label: 'you', color: WtColors.live),
              ],
            ],
          ),
        ),
      const SizedBox(height: 32),
      WtButton(
        label: _opening ? 'Hashing file…' : 'Open file',
        icon: Icons.folder_open,
        style: WtButtonStyle.ghost,
        onPressed: _opening ? null : _openFile,
      ),
      const SizedBox(height: 32),
      Text('Queue', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      if (_queue.isEmpty)
        const Text('Nothing queued', style: TextStyle(color: WtColors.muted))
      else
        for (final item in _queue)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Tooltip(
              message: item.itemRef,
              child: Text(
                item.itemRef.length > 28
                    ? '${item.itemRef.substring(0, 28)}…'
                    : item.itemRef,
                style: const TextStyle(
                  color: WtColors.muted,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
    ],
  );
}

String _fmt(int ms) {
  final s = ms ~/ 1000;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}
