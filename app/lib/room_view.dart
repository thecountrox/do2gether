/// The Room screen's presentation: top bar, stage, rail, dock, toast. Fed a [RoomViewData]
/// snapshot and callbacks, so it renders without a socket or a native player.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'media.dart' show MediaSourceKind;
import 'player.dart' show seekAtMs;
import 'room_controls.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/identity.dart';

/// Stage shape for scope files; everything else gets a 16:9 stage.
const double scopeAspect = 2.39;

/// 16:9, or 2.39:1 when the file is scope-wide; the picture letterboxes inside, never stretched.
double stageAspect(double fileAspect) =>
    fileAspect >= (16 / 9 + scopeAspect) / 2 ? scopeAspect : 16 / 9;

/// The video stage box, for layout tests.
const Key roomStageKey = ValueKey('room-stage');

/// The dock, for the fullscreen auto-hide tests.
const Key roomDockKey = ValueKey('room-dock');

/// Fullscreen chrome (dock, room cluster, cursor) hides after this long without pointer movement
/// or a key, playing or paused. The corner pills never hide.
const Duration chromeHideAfter = Duration(milliseconds: 2500);

/// How long the "Esc to exit · F toggles" hint stays up after entering fullscreen.
const Duration fullscreenHintFor = Duration(seconds: 2);

/// Fullscreen glass: the room cluster, the hint and the corner pills sit on this, never on a bar.
const BoxDecoration _glass = BoxDecoration(
  color: Color(0x99140A20),
  borderRadius: BorderRadius.all(Radius.circular(WtRadius.pill)),
  border: Border.fromBorderSide(BorderSide(color: WtColors.line, width: 1.5)),
);

enum PersonState { synced, buffering, drifting, noFile, reconnecting }

class RoomPerson {
  const RoomPerson({
    required this.id,
    required this.name,
    this.you = false,
    this.host = false,
    this.state = PersonState.synced,
    this.driftMs = 0,
  });
  final String id;
  final String name;
  final bool you;
  final bool host;
  final PersonState state;
  final double driftMs;

  /// Synced, or drifting within the seek threshold (the player is still nudging it in).
  bool get ready => switch (state) {
    PersonState.synced => true,
    PersonState.drifting => driftMs.abs() < seekAtMs,
    PersonState.buffering ||
    PersonState.noFile ||
    PersonState.reconnecting => false,
  };

  String get status => switch (state) {
    PersonState.synced => 'Synced',
    PersonState.buffering => 'Buffering',
    PersonState.drifting =>
      'Drifting ${driftMs < 0 ? '−' : '+'}${(driftMs.abs() / 1000).round()}s',
    PersonState.noFile => 'No file',
    PersonState.reconnecting => 'Reconnecting',
  };
}

/// The ready pill's tooltip: who is not ready, and why.
String readyDetail(List<RoomPerson> people) {
  final waiting = people.where((p) => !p.ready).toList();
  if (waiting.isEmpty) return 'Everyone has the file and is in sync.';
  return [
    'Not ready yet',
    for (final p in waiting) '${p.name}${p.you ? ' (you)' : ''} · ${p.status}',
  ].join('\n');
}

enum StageMode { empty, waiting, video }

/// `In sync`, or `Adjusting` while the drift policy is correcting.
enum SyncState { inSync, adjusting }

/// [source] is read off the item's ref, so it always matches what will open.
typedef QueueRow = ({String title, String detail, MediaSourceKind source});

/// Shown as a toast, then named on the stage while playback stays paused.
class PauseNotice {
  const PauseNotice({required this.serial, required this.positionMs, this.by});
  final int serial;
  final int positionMs;

  /// Who paused, when known (`You`, or the only other person).
  final String? by;
}

class RoomViewData {
  const RoomViewData({
    required this.room,
    this.title = 'Room',
    this.invite,
    this.connected = true,
    this.connecting = false,
    this.disconnectReason,
    this.people = const [],
    this.nowPlaying,
    this.upNext = const [],
    this.stage = StageMode.empty,
    this.mismatch = false,
    this.opening = false,
    this.buffering = false,
    this.error,
    this.ended = false,
    this.waitingFor,
    this.fileName,
    this.source,
    this.roomSource,
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedMs = 0,
    this.playing = false,
    this.aspect = 16 / 9,
    this.muted = false,
    this.volume = 100,
    this.rate = 1,
    this.sync,
    this.driftMs,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.fullscreen = false,
    this.pause,
  });
  final String room;
  final String title;
  final String? invite;
  final bool connected;

  /// Not connected yet for the first time, as opposed to dropped.
  final bool connecting;

  /// Set when the connection is gone for good (bad token, room ended); otherwise we retry.
  final String? disconnectReason;
  final List<RoomPerson> people;

  /// The room's item; null while nobody has pressed play.
  final QueueRow? nowPlaying;
  final List<QueueRow> upNext;
  final StageMode stage;

  /// In [StageMode.waiting]: a file is open but it is not the room's file.
  final bool mismatch;

  /// Our copy is being hashed or loaded; [fileName] names it.
  final bool opening;

  /// The player is waiting for data.
  final bool buffering;

  /// Why our copy failed to open or play, in words for the error card.
  final String? error;

  /// Our copy reached its end.
  final bool ended;

  /// Who the room waits on to press play: a name, `You`, or null when nobody can tell.
  final String? waitingFor;

  /// Our copy's display name (a Jellyfin copy's picked title, never its URL).
  final String? fileName;

  /// Where our copy comes from; null without one.
  final MediaSourceKind? source;

  /// Where the room's item comes from, for the right "open that file" action.
  final MediaSourceKind? roomSource;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final bool playing;
  final double aspect;
  final bool muted;

  /// 0–100, kept while muted.
  final double volume;

  /// The room's chosen speed. Never the drift engine's nudged rate.
  final double rate;
  final SyncState? sync;

  /// Player minus room, for the sync tooltip.
  final double? driftMs;
  final List<TrackOption> audioTracks;

  /// Includes `Off` when the player reports subtitles.
  final List<TrackOption> subtitleTracks;
  final bool fullscreen;
  final PauseNotice? pause;

  int get readyCount => people.where((p) => p.ready).length;
}

class RoomView extends StatefulWidget {
  const RoomView({
    super.key,
    required this.data,
    required this.video,
    this.onBack,
    this.onOpenFile,
    this.onOpenJellyfin,
    this.onPlay,
    this.onPause,
    this.onSeekBy,
    this.onSeekTo,
    this.onToggleMute,
    this.onVolume,
    this.onFullscreen,
    this.onSettings,
    this.onAddToQueue,
    this.onRetry,
    this.onReplay,
    this.onPlayNext,
    this.onAudioTrack,
    this.onSubtitleTrack,
  });
  final RoomViewData data;
  final Widget video;
  final VoidCallback? onBack;
  final VoidCallback? onOpenFile;

  /// Pick from the library's Jellyfin tab instead of a local file; null hides the option.
  final VoidCallback? onOpenJellyfin;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final ValueChanged<int>? onSeekBy;
  final ValueChanged<int>? onSeekTo;
  final VoidCallback? onToggleMute;
  final ValueChanged<double>? onVolume;
  final VoidCallback? onFullscreen;
  final VoidCallback? onSettings;

  /// The queue's `Add`: opens the library in queue mode.
  final VoidCallback? onAddToQueue;

  /// Open the copy that failed again.
  final VoidCallback? onRetry;

  /// Play the room's item from the start.
  final VoidCallback? onReplay;

  /// Move the room to the head of the queue.
  final VoidCallback? onPlayNext;
  final ValueChanged<String>? onAudioTrack;
  final ValueChanged<String>? onSubtitleTrack;

  @override
  State<RoomView> createState() => _RoomViewState();
}

class _RoomViewState extends State<RoomView> {
  final _playLink = LayerLink();
  bool _toast = false;
  Timer? _toastTimer;
  bool _copied = false;
  Timer? _copyTimer;

  /// The rail as an overlay sheet, below [wtCompactWidth].
  bool _sheet = false;

  /// Fullscreen chrome auto-hide. Only a real pointer arms it, so a window nobody has pointed
  /// at (and every widget test) keeps its controls.
  bool _idle = false;
  bool _pointerSeen = false;
  bool _overChrome = false;
  Timer? _idleTimer;

  /// `Show controls` is on: the fullscreen chrome stays up until it is turned off.
  bool _pinned = false;

  /// The one-off "Esc to exit · F toggles" hint after entering fullscreen.
  bool _hint = false;
  Timer? _hintTimer;

  RoomViewData get _d => widget.data;
  bool get _hasFile => _d.stage == StageMode.video;
  bool get _live => _hasFile && _d.connected;
  bool get _chromeHidden => _d.fullscreen && _idle;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    if (_d.fullscreen) _showHint();
  }

  @override
  void didUpdateWidget(RoomView old) {
    super.didUpdateWidget(old);
    final notice = _d.pause;
    if (notice == null) {
      _hideToast();
    } else if (notice.serial != old.data.pause?.serial) {
      _toastTimer?.cancel();
      _toast = true;
      _toastTimer = Timer(const Duration(seconds: 4), _hideToast);
    }
    if (old.data.fullscreen != _d.fullscreen) {
      // A control clicked on the way in or out never reports its exit; every session starts unpinned.
      _overChrome = false;
      _pinned = false;
      if (_d.fullscreen) {
        _showHint();
      } else {
        _hintTimer?.cancel();
        _hint = false;
      }
    }
    if (old.data.fullscreen != _d.fullscreen ||
        old.data.playing != _d.playing) {
      _idle = false;
      _armIdle();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _toastTimer?.cancel();
    _copyTimer?.cancel();
    _idleTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _showHint() {
    _hint = true;
    _hintTimer?.cancel();
    _hintTimer = Timer(fullscreenHintFor, () {
      if (mounted) setState(() => _hint = false);
    });
  }

  /// Any key, bound or not, counts as activity. Never consumes the event.
  bool _onKey(KeyEvent event) {
    _wake();
    return false;
  }

  void _hideToast() {
    _toastTimer?.cancel();
    if (_toast && mounted) setState(() => _toast = false);
  }

  void _copyInvite() {
    Clipboard.setData(ClipboardData(text: _d.invite ?? _d.room));
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _wake() {
    if (_idle) setState(() => _idle = false);
    _armIdle();
  }

  /// Hides the chrome after [chromeHideAfter] in fullscreen, playing or paused, unless
  /// `Show controls` is on or the pointer rests on a control.
  void _armIdle() {
    _idleTimer?.cancel();
    if (!_d.fullscreen || !_pointerSeen || _pinned) return;
    _idleTimer = Timer(chromeHideAfter, () {
      if (!mounted || !_d.fullscreen || _pinned || _overChrome) return;
      setState(() => _idle = true);
    });
  }

  void _chromeHover(bool over) {
    _overChrome = over;
    if (!over) _armIdle();
  }

  void _togglePinned() {
    setState(() {
      _pinned = !_pinned;
      _idle = false;
    });
    _armIdle();
  }

  void _showShortcuts() => showShortcutSheet(context);

  VoidCallback? get _playPause =>
      !_live ? null : (_d.playing ? widget.onPause : widget.onPlay);

  VoidCallback? _seek(int delta) =>
      _live && widget.onSeekBy != null ? () => widget.onSeekBy!(delta) : null;

  /// Why the transport is off, for its tooltips; null while it works.
  String? get _offReason => !_hasFile
      ? 'open a file first'
      : !_d.connected
      ? 'reconnecting'
      : null;

  @override
  Widget build(BuildContext context) {
    void run(VoidCallback? f) {
      _wake();
      f?.call();
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () => run(_playPause),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            run(_seek(-arrowSeekMs)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            run(_seek(arrowSeekMs)),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            run(_seek(-longSeekMs)),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            run(_seek(longSeekMs)),
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            run(_hasFile ? widget.onFullscreen : null),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            run(_hasFile ? widget.onToggleMute : null),
        const SingleActivator(LogicalKeyboardKey.escape): () => _sheet
            ? setState(() => _sheet = false)
            : run(_d.fullscreen ? widget.onFullscreen : null),
        const CharacterActivator('?'): _showShortcuts,
      },
      child: Focus(
        autofocus: true,
        // Clicks and drags count as activity too, so a long scrub never fades out mid-drag.
        child: Listener(
          onPointerDown: (_) => _wake(),
          onPointerMove: (_) => _wake(),
          child: MouseRegion(
          cursor: _chromeHidden ? SystemMouseCursors.none : MouseCursor.defer,
          onHover: (_) {
            _pointerSeen = true;
            _wake();
          },
          child: ColoredBox(
            color: _d.fullscreen ? Colors.black : WtColors.board,
            child: LayoutBuilder(
              builder: (context, box) {
                final compact = box.maxWidth < wtCompactWidth;
                return Stack(
                  children: [
                    if (_d.fullscreen)
                      _fullscreenLayout(compact: compact)
                    else
                      _windowLayout(compact: compact),
                    Positioned(
                      left: 0,
                      top: 0,
                      child: CompositedTransformFollower(
                        link: _playLink,
                        showWhenUnlinked: false,
                        targetAnchor: Alignment.topCenter,
                        followerAnchor: Alignment.bottomCenter,
                        // 12 px above the dock: the play button sits 12 px below its top edge.
                        offset: const Offset(0, -24),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 0.3),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: _toast && _d.pause != null && !_chromeHidden
                              ? _Toast(
                                  key: ValueKey(_d.pause!.serial),
                                  notice: _d.pause!,
                                  onResume: _d.connected ? widget.onPlay : null,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _windowLayout({required bool compact}) => Column(
    children: [
      _topBar(compact: compact),
      if (!_d.connected) _banner(),
      Expanded(
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _stageArea()),
                if (!compact) _Rail(data: _d, onAdd: widget.onAddToQueue),
              ],
            ),
            if (compact && _sheet) ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _sheet = false),
                  child: const ColoredBox(color: Color(0x8C000000)),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 40,
                        spreadRadius: -10,
                      ),
                    ],
                  ),
                  child: _Rail(data: _d, onAdd: widget.onAddToQueue),
                ),
              ),
            ],
          ],
        ),
      ),
      KeyedSubtree(key: roomDockKey, child: _dock(compact: compact)),
    ],
  );

  /// Fullscreen chrome: fades to nothing and stops taking clicks while idle. A no-op in the window.
  Widget _fade(Widget child) {
    final hidden = _chromeHidden;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }

  /// Resting the pointer on a control keeps the chrome up.
  Widget _hover(Widget child) => MouseRegion(
    onEnter: (_) => _chromeHover(true),
    onExit: (_) => _chromeHover(false),
    child: child,
  );

  /// The picture letterboxes on black behind everything, never moved by the chrome. The dock
  /// floats as a pill over a scrim and fades with the room cluster; the corner pills never fade.
  Widget _fullscreenLayout({required bool compact}) => Stack(
    children: [
      // Clicks on the picture or its black bars land here (the video ignores the pointer in
      // fullscreen). Anything drawn above, the dock included, keeps its own clicks.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _playPause,
          onDoubleTap: _hasFile ? widget.onFullscreen : null,
          child: const SizedBox.expand(),
        ),
      ),
      Positioned.fill(child: _stageArea()),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 260,
        child: IgnorePointer(
          child: _fade(
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x8C000000), Color(0xCC000000)],
                  stops: [0, 0.6, 1],
                ),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: 32,
        right: 32,
        bottom: 28,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: _hover(
              _fade(
                KeyedSubtree(key: roomDockKey, child: _dock(compact: compact)),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Column(
          children: [
            if (!_d.connected) _banner(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _hover(_fade(_roomCluster())),
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _hint ? 1 : 0,
                      duration: const Duration(milliseconds: 400),
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.center,
                        decoration: _glass,
                        child: const Text(
                          'Esc to exit · F toggles',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: WtColors.tx2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: _hover(_cornerPills()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  /// Top left, fades with the chrome: which room, and how many people are in it.
  Widget _roomCluster() => Tooltip(
    message: readyDetail(_d.people),
    child: Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: _glass,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              _d.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: WtColors.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            label: '${_d.people.length} in the room',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.people_alt_rounded,
                  size: 16,
                  color: WtColors.tx3,
                ),
                const SizedBox(width: 6),
                Text(
                  '${_d.people.length}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: WtColors.tx2,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// Top right for the whole fullscreen session, never faded: nobody waits for chrome to find
  /// the way out or the controls.
  Widget _cornerPills() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _CornerPill(
        label: 'Show controls',
        icon: _pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        tooltip: _pinned ? 'Let the controls fade' : 'Keep the controls up',
        on: _pinned,
        onTap: _togglePinned,
      ),
      const SizedBox(width: 8),
      _CornerPill(
        label: 'Exit fullscreen',
        icon: Icons.fullscreen_exit_rounded,
        tooltip: 'Exit fullscreen (Esc)',
        onTap: widget.onFullscreen,
      ),
    ],
  );

  Widget _topBar({required bool compact}) {
    final total = _d.people.length;
    final ready = _d.readyCount;
    final allIn = total > 0 && ready >= total;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: WtColors.plum2,
        border: Border(bottom: BorderSide(color: WtColors.line, width: 2)),
      ),
      child: Row(
        children: [
          WtIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Leave room',
            onPressed: widget.onBack,
          ),
          const SizedBox(width: 14),
          if (compact) ...[
            Semantics(
              label: 'watch together',
              excludeSemantics: true,
              child: const WtMark(size: 32),
            ),
            const SizedBox(width: 12),
          ] else ...[
            const WtWordmark(size: 17, mark: 32),
            Container(
              width: 2,
              height: 24,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              color: WtColors.line,
            ),
          ],
          Flexible(
            child: Text(
              _d.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: WtColors.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          _RoomCode(code: _d.room),
          const SizedBox(width: 4),
          WtTextButton(
            label: _copied ? 'Copied' : 'Copy invite',
            icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
            compact: true,
            onPressed: _copyInvite,
          ),
          const Spacer(),
          if (!compact) ...[
            WtTextButton(
              label: 'Shortcuts',
              icon: Icons.keyboard_rounded,
              color: WtColors.tx2,
              compact: true,
              onPressed: _showShortcuts,
            ),
            const SizedBox(width: 8),
          ],
          Tooltip(
            message: readyDetail(_d.people),
            child: Semantics(
              liveRegion: true,
              child: WtPill(
                label: readyPillLabel(ready, total),
                tone: allIn ? WtTone.live : WtTone.warn,
                dot: allIn ? WtDotStyle.solid : WtDotStyle.ring,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (compact) ...[
            WtIconButton(
              icon: Icons.people_alt_rounded,
              tooltip: _sheet ? 'Hide people and queue' : 'People and queue',
              background: _sheet ? WtColors.s2 : WtColors.s1,
              onPressed: () => setState(() => _sheet = !_sheet),
            ),
            const SizedBox(width: 12),
          ],
          WtIconButton(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: widget.onSettings,
          ),
        ],
      ),
    );
  }

  Widget _banner() => Semantics(
    liveRegion: true,
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0x1FFFD45E),
        border: Border(bottom: BorderSide(color: Color(0x66FFD45E), width: 2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          WtDot(
            color: WtColors.yellow,
            style: _d.disconnectReason == null
                ? WtDotStyle.pulse
                : WtDotStyle.ring,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _d.disconnectReason != null
                  ? 'Disconnected: ${_d.disconnectReason}'
                  : _d.connecting
                  ? 'Connecting to the room…'
                  : 'Reconnecting… the room stays here; controls come back when we are.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: WtColors.yellow,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _stageArea() {
    final stage = LayoutBuilder(
      builder: (context, box) {
        final aspect = _hasFile ? stageAspect(_d.aspect) : 16 / 9;
        final width = math.min(
          math.min(box.maxWidth, _d.fullscreen ? box.maxWidth : 1072.0),
          box.maxHeight * aspect,
        );
        return Center(
          child: SizedBox(
            key: roomStageKey,
            width: width,
            height: width / aspect,
            child: _stage(),
          ),
        );
      },
    );
    // Fullscreen: straight onto the black, no backdrop and no window margin.
    if (_d.fullscreen) return stage;
    return WtBackdrop(
      color: WtColors.board,
      child: Padding(
        padding: const EdgeInsets.all(WtSpace.window),
        child: stage,
      ),
    );
  }

  /// The local-file or Jellyfin picker, whichever fits [source]; the file picker by default.
  VoidCallback? _opener(MediaSourceKind? source) =>
      source == MediaSourceKind.jellyfin && widget.onOpenJellyfin != null
      ? widget.onOpenJellyfin
      : widget.onOpenFile;

  Widget _stage() {
    final error = _d.error;
    if (error != null) {
      return _StagePanel(
        outline: WtColors.danger,
        tile: const _GlowTile(
          glow: Color(0x59FF6B6B),
          child: Icon(
            Icons.error_outline_rounded,
            size: 32,
            color: WtColors.danger,
          ),
        ),
        title: "Couldn't play ${_d.fileName ?? 'your copy'}",
        body: error,
        actions: [
          WtButton(
            label: 'Try again',
            icon: Icons.refresh_rounded,
            onPressed: widget.onRetry,
          ),
          WtButton(
            label: 'Choose another file',
            icon: Icons.folder_open_rounded,
            style: WtButtonStyle.ghost,
            onPressed: _opener(_d.source),
          ),
        ],
      );
    }
    if (_d.opening) {
      return _StagePanel(
        outline: WtColors.line,
        tile: const _GlowTile(child: _Spinner()),
        title: 'Opening your copy…',
        body: _d.fileName ?? 'Checking the file.',
        live: true,
      );
    }
    switch (_d.stage) {
      case StageMode.video:
        final full = _d.fullscreen;
        return Stack(
          fit: StackFit.expand,
          children: [
            // In fullscreen, clicks pass through the picture to the stage's play/pause.
            IgnorePointer(
              ignoring: full,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(full ? 0 : 10),
                child: ColoredBox(
                  color: full ? Colors.black : WtColors.board,
                  child: widget.video,
                ),
              ),
            ),
            ?_videoOverlay(),
          ],
        );
      case StageMode.empty:
        return _StagePanel(
          outline: WtColors.line,
          tile: const _GlowTile(
            child: Icon(Icons.add_rounded, size: 32, color: WtColors.pink),
          ),
          title: 'Open a file to watch together',
          body: 'It plays from your disk. Everyone opens their own copy.',
          actions: [
            WtButton(
              label: 'Open file',
              icon: Icons.folder_open_rounded,
              onPressed: widget.onOpenFile,
            ),
            if (widget.onOpenJellyfin != null)
              WtButton(
                label: 'Or pick from Jellyfin',
                icon: Icons.dns_rounded,
                style: WtButtonStyle.ghost,
                onPressed: widget.onOpenJellyfin,
              ),
          ],
        );
      case StageMode.waiting:
        final room = _d.nowPlaying;
        final roomFile = room == null
            ? "the room's file"
            : room.detail.isEmpty
            ? room.title
            : '${room.title} (${room.detail})';
        final jellyfin = _d.roomSource == MediaSourceKind.jellyfin;
        return _StagePanel(
          outline: WtColors.yellow,
          tile: const WtDashed(
            color: Color(0x99FFD45E),
            radius: 20,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(
                Icons.schedule_rounded,
                size: 30,
                color: WtColors.yellow,
              ),
            ),
          ),
          title: _d.mismatch
              ? "That's not the room's file"
              : "Open the room's file to join",
          body: _d.mismatch
              ? 'You opened ${_d.fileName ?? 'a different file'}. The room is playing $roomFile.'
              : 'The room is playing $roomFile. Open your own copy of it.',
          actions: [
            WtButton(
              label: 'Open that file…',
              icon: jellyfin ? Icons.dns_rounded : Icons.folder_open_rounded,
              onPressed: _opener(_d.roomSource),
            ),
            if (jellyfin && widget.onOpenJellyfin != null)
              WtButton(
                label: 'Open a local file',
                icon: Icons.folder_open_rounded,
                style: WtButtonStyle.ghost,
                onPressed: widget.onOpenFile,
              )
            else if (!jellyfin && widget.onOpenJellyfin != null)
              WtButton(
                label: 'Or pick from Jellyfin',
                icon: Icons.dns_rounded,
                style: WtButtonStyle.ghost,
                onPressed: widget.onOpenJellyfin,
              ),
          ],
        );
    }
  }

  /// Buffering, ended or paused, over the picture; nothing while it plays.
  Widget? _videoOverlay() {
    if (_d.buffering) {
      return Center(
        child: _StageNote(
          lead: const _Spinner(),
          title: 'Buffering…',
          body: _d.fileName,
        ),
      );
    }
    if (_d.ended) {
      final next = _d.upNext.isEmpty ? null : _d.upNext.first.title;
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0x99000000)),
          Center(
            child: _StageNote(
              lead: const Icon(
                Icons.check_circle_rounded,
                size: 28,
                color: WtColors.cyan,
              ),
              title: 'Finished',
              body: next == null ? _d.fileName : 'Up next: $next',
              actions: [
                WtButton(
                  label: 'Replay',
                  icon: Icons.replay_rounded,
                  size: WtButtonSize.small,
                  style: next == null
                      ? WtButtonStyle.primary
                      : WtButtonStyle.ghost,
                  onPressed: _d.connected ? widget.onReplay : null,
                ),
                if (next != null)
                  WtButton(
                    label: 'Play next',
                    icon: Icons.skip_next_rounded,
                    size: WtButtonSize.small,
                    onPressed: _d.connected ? widget.onPlayNext : null,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (!_d.playing && !_toast) {
      final who = _d.waitingFor;
      final idle = _d.nowPlaying == null;
      final at = fmtTime(_d.positionMs);
      final (title, body) = switch (who) {
        'You' when idle => (
          'Nobody has pressed play yet',
          'Press play to start it for everyone.',
        ),
        'You' => (
          'You paused for everyone',
          'Paused at $at. Press play to carry on.',
        ),
        final name? => (
          'Waiting for $name to press play',
          idle
              ? 'Anyone can start it once everyone is ready.'
              : 'Paused at $at. Anyone can press play.',
        ),
        null when idle => (
          'Nobody has pressed play yet',
          'Press play to start it for everyone.',
        ),
        null => (
          'Waiting for someone to press play',
          'Paused at $at. Anyone can press play.',
        ),
      };
      // In fullscreen the paused card is chrome: it fades with the dock.
      return _fade(
        Center(
        child: _StageNote(
          lead: who == null || who == 'You'
              ? const Icon(
                  Icons.pause_circle_rounded,
                  size: 28,
                  color: WtColors.tx2,
                )
              : WtAvatar(id: who, name: who, size: 32),
          title: title,
          body: body,
          actions: [
            WtButton(
              label: 'Play for everyone',
              icon: Icons.play_arrow_rounded,
              size: WtButtonSize.small,
              onPressed: _playPause,
            ),
          ],
        ),
        ),
      );
    }
    return null;
  }

  /// [compact] drops the now-playing title (it is in the queue sheet) so the scrubber keeps its width.
  /// In fullscreen the same controls float as a translucent pill instead of a bar.
  Widget _dock({required bool compact}) {
    final off = _offReason;
    String tip(String what) => off == null ? what : '$what · $off';
    return Container(
      height: 88,
      padding: EdgeInsets.symmetric(horizontal: _d.fullscreen ? 28 : 24),
      decoration: _d.fullscreen
          ? BoxDecoration(
              color: const Color(0xD91A0E27),
              borderRadius: BorderRadius.circular(WtRadius.pill),
              border: Border.all(color: WtColors.line, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x99000000),
                  offset: Offset(0, 16),
                  blurRadius: 40,
                  spreadRadius: -12,
                ),
              ],
            )
          : const BoxDecoration(
              color: WtColors.plum2,
              border: Border(top: BorderSide(color: WtColors.line, width: 2)),
            ),
      child: Row(
        children: [
          if (!compact) ...[
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: _nowPlaying(),
              ),
            ),
            const SizedBox(width: 16),
          ],
          _SkipChip(
            label: '−10s',
            tooltip: tip('Back 10 seconds'),
            onTap: _seek(-skipMs),
          ),
          const SizedBox(width: 10),
          CompositedTransformTarget(
            link: _playLink,
            child: _PlayButton(playing: _d.playing, onTap: _playPause),
          ),
          const SizedBox(width: 10),
          _SkipChip(
            label: '+10s',
            tooltip: tip('Ahead 10 seconds'),
            onTap: _seek(skipMs),
          ),
          const SizedBox(width: 16),
          _timeBlock(),
          const SizedBox(width: 16),
          Expanded(
            child: Opacity(
              opacity: _live ? 1 : 0.4,
              child: WtScrubber(
                positionMs: _d.positionMs,
                durationMs: _d.durationMs,
                bufferedMs: _d.bufferedMs,
                onSeek: _live ? widget.onSeekTo : null,
              ),
            ),
          ),
          const SizedBox(width: 16),
          if (_hasFile &&
              TrackMenu.hasChoice(_d.audioTracks, _d.subtitleTracks)) ...[
            TrackMenu(
              audio: _d.audioTracks,
              subtitles: _d.subtitleTracks,
              onAudio: widget.onAudioTrack,
              onSubtitle: widget.onSubtitleTrack,
            ),
            const SizedBox(width: 8),
          ],
          VolumeControl(
            volume: _d.volume,
            muted: _d.muted,
            onToggleMute: _hasFile ? widget.onToggleMute : null,
            onVolume: _hasFile ? widget.onVolume : null,
          ),
          const SizedBox(width: 8),
          WtIconButton(
            icon: _d.fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: _d.fullscreen ? 'Exit fullscreen (F)' : 'Fullscreen (F)',
            onPressed: _hasFile ? widget.onFullscreen : null,
          ),
          const SizedBox(width: 8),
          WtIconButton(
            icon: Icons.question_mark_rounded,
            tooltip: 'Keyboard shortcuts (?)',
            onPressed: _showShortcuts,
          ),
        ],
      ),
    );
  }

  Widget _nowPlaying() => Opacity(
    opacity: _hasFile ? 1 : 0.4,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Now playing',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: WtColors.tx3,
              ),
            ),
            if (_d.source case final source?) ...[
              const SizedBox(width: 8),
              _SourceChip(source: source),
            ],
          ],
        ),
        const SizedBox(height: 2),
        WtMidText(
          _d.fileName ?? 'No file open',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: WtColors.text,
          ),
        ),
      ],
    ),
  );

  /// Position and length, with the sync state and a non-1× room speed under it.
  Widget _timeBlock() {
    final sync = _hasFile ? _d.sync : null;
    final speed = _hasFile && _d.rate != 1;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: _hasFile ? 1 : 0.4,
          child: Text(
            '${fmtTime(_d.positionMs)} / ${fmtTime(_d.durationMs)}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: WtColors.text,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (sync != null || speed) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sync != null) _SyncTag(sync: sync, driftMs: _d.driftMs),
              if (sync != null && speed) const SizedBox(width: 8),
              if (speed)
                Tooltip(
                  message: 'Room speed',
                  child: Text(
                    fmtSpeed(_d.rate),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: WtColors.pink,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onTap,
    radius: 24,
    tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
    semanticLabel: playing ? 'Pause' : 'Play',
    child: Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: onTap == null ? null : WtColors.glow,
      ),
      child: WtInsetHighlight(
        radius: 24,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: WtColors.grad,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x3DFFFFFF), width: 2),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 120),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: 38,
                color: WtColors.text,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// `−10s` / `+10s`: quiet, labelled, so the play button stays the one loud control.
class _SkipChip extends StatelessWidget {
  const _SkipChip({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WtRadius.control),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: WtColors.tx2,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

/// A quiet glass pill for the fullscreen corner: always readable, low enough in contrast that it
/// does not fight the picture. [on] makes it a toggle.
class _CornerPill extends StatelessWidget {
  const _CornerPill({
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.on,
  });
  final String label;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool? on;

  @override
  Widget build(BuildContext context) {
    final lit = on ?? false;
    return Semantics(
      toggled: on,
      child: WtTap(
        onTap: onTap,
        radius: 18,
        tooltip: tooltip,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: _glass,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: lit ? WtColors.pink : WtColors.tx3),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: lit ? WtColors.tx2 : WtColors.tx3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The room code as one labelled chip. Key caps are for keys (the shortcut sheet), not codes.
class _RoomCode extends StatelessWidget {
  const _RoomCode({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Room code ${code.toUpperCase().split('').join(' ')}',
    excludeSemantics: true,
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: WtColors.s1,
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'ROOM',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
              color: WtColors.tx3,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            codeGroups(code).join('-').toUpperCase(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: WtColors.text,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});
  final MediaSourceKind source;

  @override
  Widget build(BuildContext context) {
    final jellyfin = source == MediaSourceKind.jellyfin;
    final color = jellyfin ? WtColors.pink : WtColors.tx3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: jellyfin ? WtColors.pink : WtColors.line,
          width: 1.5,
        ),
      ),
      child: Text(
        jellyfin ? 'Jellyfin' : 'Local file',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _SyncTag extends StatelessWidget {
  const _SyncTag({required this.sync, required this.driftMs});
  final SyncState sync;
  final double? driftMs;

  @override
  Widget build(BuildContext context) {
    final inSync = sync == SyncState.inSync;
    final color = inSync ? WtColors.cyan : WtColors.yellow;
    final drift = driftMs;
    return Tooltip(
      message: drift == null
          ? (inSync ? 'Matching the room' : 'Catching up with the room')
          : inSync
          ? 'Within ${drift.abs().round()} ms of the room'
          : '${(drift.abs() / 1000).toStringAsFixed(1)} s '
                '${drift < 0 ? 'behind' : 'ahead of'} the room, catching up',
      child: Semantics(
        liveRegion: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            WtDot(color: color, style: WtDotStyle.solid),
            const SizedBox(width: 6),
            Text(
              inSync ? 'In sync' : 'Adjusting',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 28,
    height: 28,
    child: CircularProgressIndicator(
      strokeWidth: 3.5,
      strokeCap: StrokeCap.round,
      color: WtColors.pink,
      backgroundColor: Color(0x33FF5FAE),
    ),
  );
}

/// A card over the picture: buffering, finished, paused.
class _StageNote extends StatelessWidget {
  const _StageNote({
    required this.lead,
    required this.title,
    this.body,
    this.actions = const [],
  });
  final Widget lead;
  final String title;
  final String? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 440),
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xEB140A20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: WtColors.line, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            offset: Offset(0, 12),
            blurRadius: 30,
            spreadRadius: -10,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              lead,
              const SizedBox(width: 14),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                        color: WtColors.text,
                      ),
                    ),
                    if (body case final b?) ...[
                      const SizedBox(height: 2),
                      Text(
                        b,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: WtColors.tx3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: actions),
          ],
        ],
      ),
    ),
  );
}

class _StagePanel extends StatelessWidget {
  const _StagePanel({
    required this.outline,
    required this.tile,
    required this.title,
    required this.body,
    this.actions = const [],
    this.live = false,
  });
  final Color outline;
  final Widget tile;
  final String title;
  final String body;

  /// The primary action first, then quieter alternatives.
  final List<Widget> actions;

  /// Announce the panel to screen readers when it appears (loading states).
  final bool live;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: live,
    child: Container(
      decoration: BoxDecoration(
        color: WtColors.plum,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: outline, width: 2),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile,
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: WtColors.tx3,
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _GlowTile extends StatelessWidget {
  const _GlowTile({required this.child, this.glow = const Color(0x59D93583)});
  final Widget child;
  final Color glow;

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 64,
    decoration: BoxDecoration(
      color: WtColors.s1,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: WtColors.line, width: 2),
      boxShadow: [BoxShadow(color: glow, blurRadius: 40, spreadRadius: 4)],
    ),
    child: Center(child: child),
  );
}

class _Toast extends StatelessWidget {
  const _Toast({super.key, required this.notice, required this.onResume});
  final PauseNotice notice;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final by = notice.by;
    const bg = Color(0xEB140A20);
    return Semantics(
      liveRegion: true,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(WtRadius.pill),
          border: Border.all(color: WtColors.line, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x80000000),
              offset: Offset(0, 12),
              blurRadius: 30,
              spreadRadius: -10,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(WtRadius.pill),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(left: by == null ? 16 : 6, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (by == null)
                      const Icon(
                        Icons.pause_rounded,
                        size: 20,
                        color: WtColors.tx2,
                      )
                    else
                      WtAvatar(id: by, name: by, size: 32, ring: bg),
                    const SizedBox(width: 10),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (by != null)
                            TextSpan(
                              text: '$by ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          TextSpan(
                            text: by == null
                                ? 'Paused for everyone · ${fmtTime(notice.positionMs)}'
                                : 'paused for everyone · ${fmtTime(notice.positionMs)}',
                          ),
                        ],
                      ),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: WtColors.text,
                      ),
                    ),
                    const SizedBox(width: 6),
                    WtTextButton(
                      label: 'Resume',
                      compact: true,
                      onPressed: onResume,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: const Duration(seconds: 4),
                  builder: (context, value, _) => FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: value,
                    child: const ColoredBox(color: WtColors.pink),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.data, required this.onAdd});
  final RoomViewData data;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final now = data.nowPlaying;
    return Container(
      width: 320,
      decoration: const BoxDecoration(
        color: WtColors.plum2,
        border: Border(left: BorderSide(color: WtColors.line, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(WtSpace.rail),
              children: [
                WtLabel(
                  'In this room',
                  trailing: Text(
                    '${data.people.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: WtColors.tx3,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final p in data.people) ...[
                  _PersonTile(person: p),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 12),
                const Divider(height: 2, thickness: 2, color: WtColors.line),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: WtLabel('Queue')),
                    WtButton(
                      label: 'Add',
                      icon: Icons.add_rounded,
                      style: WtButtonStyle.ghost,
                      size: WtButtonSize.small,
                      onPressed: data.connected ? onAdd : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (now != null) _QueueTile(row: now, now: true),
                if (data.upNext.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const WtLabel('Up next'),
                  const SizedBox(height: 6),
                  for (final row in data.upNext) _QueueTile(row: row),
                ] else ...[
                  const SizedBox(height: 10),
                  const _EmptyQueue(),
                ],
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
              'Voice stays in Discord. This room only keeps time.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: WtColors.tx3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person});
  final RoomPerson person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final warn =
        p.state == PersonState.noFile || p.state == PersonState.drifting;
    final (color, dot) = switch (p.state) {
      PersonState.synced => (WtColors.cyan, WtDotStyle.solid),
      PersonState.buffering => (WtColors.yellow, WtDotStyle.ring),
      PersonState.drifting => (WtColors.yellow, WtDotStyle.solid),
      PersonState.noFile => (WtColors.yellow, WtDotStyle.ring),
      PersonState.reconnecting => (WtColors.tx3, WtDotStyle.pulse),
    };
    final row = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: warn
          ? BoxDecoration(
              color: const Color(0x12FFD45E),
              borderRadius: BorderRadius.circular(WtRadius.control),
            )
          : null,
      child: Row(
        children: [
          WtAvatar(
            id: p.id,
            name: p.name,
            muted: p.state == PersonState.reconnecting,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: WtColors.text,
                        ),
                      ),
                    ),
                    if (p.you)
                      const Text(
                        ' (you)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: WtColors.tx3,
                        ),
                      ),
                    if (p.host) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: WtColors.pink, width: 1.5),
                        ),
                        child: const Text(
                          'HOST',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.8,
                            color: WtColors.pink,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    WtDot(color: color, style: dot),
                    const SizedBox(width: 6),
                    Text(
                      p.status,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: warn ? WtColors.yellow : WtColors.tx3,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return warn
        ? WtDashed(
            color: const Color(0x66FFD45E),
            radius: WtRadius.control,
            child: row,
          )
        : row;
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.row, this.now = false});
  final QueueRow row;
  final bool now;

  @override
  Widget build(BuildContext context) => Container(
    height: 56,
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: now
        ? BoxDecoration(
            color: WtColors.s1,
            borderRadius: BorderRadius.circular(WtRadius.control),
            border: const Border(
              left: BorderSide(color: WtColors.pink, width: 3),
            ),
          )
        : null,
    child: Row(
      children: [
        WtFileGlyph(size: 24, color: now ? WtColors.pink : WtColors.tx3),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WtMidText(
                row.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: WtColors.text,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  _SourceChip(source: row.source),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      now
                          ? (row.detail.isEmpty
                                ? 'Now playing'
                                : 'Now playing · ${row.detail}')
                          : row.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: now ? WtColors.pink : WtColors.tx3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) => WtDashed(
    color: WtColors.line,
    radius: WtRadius.control,
    child: const Padding(
      padding: EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nothing queued',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: WtColors.text,
            ),
          ),
          SizedBox(height: 2),
          Text(
            'Add the next episode so nobody has to ask.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: WtColors.tx3,
            ),
          ),
        ],
      ),
    ),
  );
}
