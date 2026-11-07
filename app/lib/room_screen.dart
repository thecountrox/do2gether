import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player.dart';
import 'protocol.dart';
import 'room_client.dart';

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
  });

  final Uri server;
  final String room;
  final String token;
  final String name;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final RoomClient _client;
  final SyncPlayer _player = SyncPlayer();
  late final Timer _pollTimer;
  late final Timer _reportTimer;
  final List<Member> _members = [];
  int _rev = 0;
  Playback? _anchor;
  bool _clockWasReady = false;
  bool _opening = false;

  bool get _joined => _client.status == ConnectionStatus.joined;

  @override
  void initState() {
    super.initState();
    _client = RoomClient(
      server: widget.server,
      room: widget.room,
      token: widget.token,
      name: widget.name,
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
          _members
            ..clear()
            ..addAll(snapshot.presence);
        });
        _apply();
      case StateMsg state when state.rev > _rev:
        setState(() {
          _rev = state.rev;
          _anchor = state.playback;
        });
        _apply();
      case PresenceMsg p:
        setState(() {
          _members.removeWhere((m) => m.userId == p.userId);
          if (p.joined) _members.add(Member(userId: p.userId, name: p.name));
        });
      case RejectMsg(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    if (_joined && _client.clock.ready) _client.sendReport(_player.driftMs ?? 0);
  }

  Future<void> _openFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() => _opening = true);
    try {
      await _player.open(file.path);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open failed: $e')));
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
    final now = anchor == null ? _player.positionMs : positionAt(anchor, _client.clock.serverNow());
    _client.sendIntent('seek', {'position_ms': math.max(0, now + deltaMs)});
  }

  String get _matchState {
    final anchor = _anchor;
    if (_player.itemRef == null) return 'no local file';
    if (anchor == null) return 'room is idle';
    return anchor.itemRef == _player.itemRef ? 'local file matches' : 'waiting for host file';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Room ${widget.room}')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _videoArea()),
                _controls(),
                _nowPlaying(context),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(width: 280, child: _sidebar(context)),
        ],
      ),
    );
  }

  Widget _videoArea() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: _player.video,
          controls: NoVideoControls,
          pauseUponEnteringBackgroundMode: false,
        ),
        if (_player.itemRef == null || _matchState == 'waiting for host file')
          Center(
            child: Text(
              _opening ? 'Hashing file…' : _matchState,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ),
      ],
    );
  }

  Widget _controls() {
    final enabled = _joined;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _opening ? null : _openFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open file…'),
          ),
          FilledButton.icon(
            onPressed: enabled ? _play : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
          ),
          FilledButton.tonalIcon(
            onPressed: enabled ? _pause : null,
            icon: const Icon(Icons.pause),
            label: const Text('Pause'),
          ),
          OutlinedButton(
            onPressed: enabled ? () => _seekBy(-seekStepMs) : null,
            child: const Text('-10 s'),
          ),
          OutlinedButton(
            onPressed: enabled ? () => _seekBy(seekStepMs) : null,
            child: const Text('+10 s'),
          ),
        ],
      ),
    );
  }

  Widget _nowPlaying(BuildContext context) {
    final anchor = _anchor;
    final room = anchor == null
        ? 'nothing'
        : '${anchor.itemRef} (${anchor.paused ? 'paused' : 'playing'} at ${_fmt(positionAt(anchor, _client.clock.serverNow()))})';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: DefaultTextStyle.merge(
        style: Theme.of(context).textTheme.bodySmall,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText('Now playing: $room'),
            SelectableText('Local file: ${_player.path ?? '—'}  ${_player.itemRef ?? ''}'),
            Text('Match: $_matchState · player: ${_player.status}'),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(BuildContext context) {
    final clock = _client.clock;
    final drift = _player.driftMs;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Connection', style: text.titleSmall),
        Text(_client.status.name),
        if (_client.closeReason case final reason? when _client.status == ConnectionStatus.closed)
          Text(reason, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
        Text('Sync', style: text.titleSmall),
        Text(
          clock.ready
              ? 'offset ${clock.offsetMs.toStringAsFixed(1)} ms · rtt ${clock.rttMs.toStringAsFixed(1)} ms'
              : 'clock syncing…',
        ),
        Text('rev $_rev'),
        Text('drift ${drift == null ? '—' : '${drift.round()} ms'}'),
        const SizedBox(height: 12),
        Text('People (${_members.length})', style: text.titleSmall),
        for (final m in _members)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(m.name ?? m.userId),
            subtitle: m.userId == _client.clientId ? const Text('you') : null,
          ),
      ],
    );
  }
}

String _fmt(int ms) {
  final s = ms ~/ 1000;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}
