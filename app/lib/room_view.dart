/// The Room screen's presentation: top bar, stage, rail, dock, toast. Fed a [RoomViewData]
/// snapshot and callbacks, so it renders without a socket or a native player.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'player.dart' show seekAtMs;
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/identity.dart';

const int seekStepMs = 10000;

/// Stage shape for scope files; everything else gets a 16:9 stage.
const double scopeAspect = 2.39;

/// 16:9, or 2.39:1 when the file is scope-wide; the picture letterboxes inside, never stretched.
double stageAspect(double fileAspect) =>
    fileAspect >= (16 / 9 + scopeAspect) / 2 ? scopeAspect : 16 / 9;

/// The video stage box, for layout tests.
const Key roomStageKey = ValueKey('room-stage');

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

enum StageMode { empty, waiting, video }

typedef QueueRow = ({String title, String detail});

/// Shown as a toast, then as a badge on the stage while playback stays paused.
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
    this.fileName,
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedMs = 0,
    this.playing = false,
    this.aspect = 16 / 9,
    this.muted = false,
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
  final QueueRow? nowPlaying;
  final List<QueueRow> upNext;
  final StageMode stage;

  /// In [StageMode.waiting]: a file is open but it is not the room's file.
  final bool mismatch;
  final bool opening;
  final String? fileName;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final bool playing;
  final double aspect;
  final bool muted;
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
    this.onPlay,
    this.onPause,
    this.onSeekBy,
    this.onSeekTo,
    this.onToggleMute,
    this.onFullscreen,
    this.onSettings,
    this.onAddToQueue,
  });
  final RoomViewData data;
  final Widget video;
  final VoidCallback? onBack;
  final VoidCallback? onOpenFile;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final ValueChanged<int>? onSeekBy;
  final ValueChanged<int>? onSeekTo;
  final VoidCallback? onToggleMute;
  final VoidCallback? onFullscreen;
  final VoidCallback? onSettings;
  final VoidCallback? onAddToQueue;

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

  RoomViewData get _d => widget.data;
  bool get _hasFile => _d.stage == StageMode.video;
  bool get _live => _hasFile && _d.connected;

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
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _copyTimer?.cancel();
    super.dispose();
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

  VoidCallback? get _playPause =>
      !_live ? null : (_d.playing ? widget.onPause : widget.onPlay);

  VoidCallback? _seek(int delta) =>
      _live && widget.onSeekBy != null ? () => widget.onSeekBy!(delta) : null;

  @override
  Widget build(BuildContext context) {
    void run(VoidCallback? f) => f?.call();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () => run(_playPause),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            run(_seek(-seekStepMs)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            run(_seek(seekStepMs)),
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            run(_hasFile ? widget.onFullscreen : null),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            run(_hasFile ? widget.onToggleMute : null),
        const SingleActivator(LogicalKeyboardKey.escape): () => _sheet
            ? setState(() => _sheet = false)
            : run(_d.fullscreen ? widget.onFullscreen : null),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: WtColors.board,
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxWidth < wtCompactWidth;
              final rail = !_d.fullscreen;
              return Stack(
                children: [
                  Column(
                    children: [
                      if (!_d.fullscreen) _topBar(compact: compact),
                      if (!_d.connected) _banner(),
                      Expanded(
                        child: Stack(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _stageArea()),
                                if (rail && !compact)
                                  _Rail(data: _d, onAdd: widget.onAddToQueue),
                              ],
                            ),
                            if (rail && compact && _sheet) ...[
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _sheet = false),
                                  child: const ColoredBox(
                                    color: Color(0x8C000000),
                                  ),
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
                                  child: _Rail(
                                    data: _d,
                                    onAdd: widget.onAddToQueue,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      _dock(compact: compact),
                    ],
                  ),
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
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.3),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _toast && _d.pause != null
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
    );
  }

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
          WtKeyCaps(code: _d.room, size: WtKeySize.small),
          const SizedBox(width: 4),
          WtTextButton(
            label: _copied ? 'Copied' : 'Copy invite',
            icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
            compact: true,
            onPressed: _copyInvite,
          ),
          const Spacer(),
          Semantics(
            liveRegion: true,
            child: WtPill(
              label: readyPillLabel(ready, total),
              tone: allIn ? WtTone.live : WtTone.warn,
              dot: allIn ? WtDotStyle.solid : WtDotStyle.ring,
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

  Widget _stageArea() => WtBackdrop(
    color: WtColors.board,
    child: Padding(
      padding: const EdgeInsets.all(WtSpace.window),
      child: LayoutBuilder(
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
      ),
    ),
  );

  Widget _stage() {
    switch (_d.stage) {
      case StageMode.video:
        final notice = _d.pause;
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(color: WtColors.board, child: widget.video),
            ),
            if (notice != null && !_d.playing && !_toast)
              Positioned(left: 12, top: 12, child: _Badge(notice: notice)),
          ],
        );
      case StageMode.empty:
        return _StagePanel(
          outline: WtColors.line,
          tile: _GlowTile(
            child: Icon(
              _d.opening ? Icons.hourglass_top_rounded : Icons.add_rounded,
              size: 32,
              color: WtColors.pink,
            ),
          ),
          title: _d.opening
              ? 'Checking your file…'
              : 'Open a file to watch together',
          body: 'It plays from your disk. Everyone opens their own copy.',
          action: WtButton(
            label: 'Open file',
            icon: Icons.folder_open_rounded,
            onPressed: _d.opening ? null : widget.onOpenFile,
          ),
        );
      case StageMode.waiting:
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
          title: "Waiting for the host's file",
          body: _d.mismatch
              ? "The file you opened isn't the one the room is playing."
              : 'Open the same file the host is playing.',
          action: WtButton(
            label: _d.mismatch ? 'Open a different file' : 'Open file',
            icon: Icons.folder_open_rounded,
            style: WtButtonStyle.ghost,
            onPressed: _d.opening ? null : widget.onOpenFile,
          ),
        );
    }
  }

  /// [compact] drops the now-playing title (it is in the queue sheet) so the scrubber keeps its width.
  Widget _dock({required bool compact}) {
    const timeStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w800,
      color: WtColors.text,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Container(
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: WtColors.plum2,
        border: Border(top: BorderSide(color: WtColors.line, width: 2)),
      ),
      child: Row(
        children: [
          if (!compact) ...[
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Opacity(
                  opacity: _hasFile ? 1 : 0.4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Now playing',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: WtColors.tx3,
                        ),
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
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
          _SkipButton(back: true, onTap: _seek(-seekStepMs)),
          const SizedBox(width: 12),
          CompositedTransformTarget(
            link: _playLink,
            child: _PlayButton(playing: _d.playing, onTap: _playPause),
          ),
          const SizedBox(width: 12),
          _SkipButton(back: false, onTap: _seek(seekStepMs)),
          const SizedBox(width: 16),
          Opacity(
            opacity: _hasFile ? 1 : 0.4,
            child: Text(
              '${fmtTime(_d.positionMs)} / ${fmtTime(_d.durationMs)}',
              style: timeStyle,
            ),
          ),
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
          WtIconButton(
            icon: _d.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            tooltip: _d.muted ? 'Unmute (M)' : 'Mute (M)',
            onPressed: _hasFile ? widget.onToggleMute : null,
          ),
          const SizedBox(width: 8),
          WtIconButton(
            icon: _d.fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: _d.fullscreen ? 'Exit fullscreen (F)' : 'Fullscreen (F)',
            onPressed: _hasFile ? widget.onFullscreen : null,
          ),
        ],
      ),
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
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 34,
              color: WtColors.text,
            ),
          ),
        ),
      ),
    ),
  );
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.back, required this.onTap});
  final bool back;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onTap,
    tooltip: back ? 'Back 10s (←)' : 'Ahead 10s (→)',
    semanticLabel: back ? 'Back 10s' : 'Ahead 10s',
    child: Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: WtColors.s1,
        borderRadius: BorderRadius.circular(WtRadius.control),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            back ? Icons.replay_rounded : Icons.forward_rounded,
            size: 20,
            color: WtColors.text,
          ),
          const SizedBox(width: 4),
          const Text(
            '10',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: WtColors.text,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Thick seek bar: 8 px track, buffered hint, pink fill, 14 px handle, 44 px hit area.
class WtScrubber extends StatefulWidget {
  const WtScrubber({
    super.key,
    required this.positionMs,
    required this.durationMs,
    required this.bufferedMs,
    this.onSeek,
  });
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final ValueChanged<int>? onSeek;

  @override
  State<WtScrubber> createState() => _WtScrubberState();
}

class _WtScrubberState extends State<WtScrubber> {
  double? _drag;
  bool _focused = false;

  int get _total => widget.durationMs;
  bool get _enabled => widget.onSeek != null && _total > 0;

  double _fraction(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  void _seekFraction(double f) => widget.onSeek?.call((f * _total).round());

  void _step(int delta) =>
      widget.onSeek?.call((widget.positionMs + delta).clamp(0, _total));

  @override
  Widget build(BuildContext context) {
    final pos = math.min(math.max(0, widget.positionMs), math.max(0, _total));
    final played = _drag ?? (_total > 0 ? pos / _total : 0.0);
    final buffered = _total > 0
        ? (widget.bufferedMs / _total).clamp(0.0, 1.0)
        : 0.0;
    return Semantics(
      slider: true,
      label: 'Seek',
      enabled: _enabled,
      value: fmtTimeWords(pos),
      increasedValue: fmtTimeWords(math.min(_total, pos + seekStepMs)),
      decreasedValue: fmtTimeWords(math.max(0, pos - seekStepMs)),
      onIncrease: _enabled ? () => _step(seekStepMs) : null,
      onDecrease: _enabled ? () => _step(-seekStepMs) : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _enabled
                  ? (d) => _seekFraction(_fraction(d.localPosition.dx, width))
                  : null,
              onHorizontalDragStart: _enabled
                  ? (d) => setState(
                      () => _drag = _fraction(d.localPosition.dx, width),
                    )
                  : null,
              onHorizontalDragUpdate: _enabled
                  ? (d) => setState(
                      () => _drag = _fraction(d.localPosition.dx, width),
                    )
                  : null,
              onHorizontalDragEnd: _enabled
                  ? (_) {
                      final f = _drag;
                      setState(() => _drag = null);
                      if (f != null) _seekFraction(f);
                    }
                  : null,
              onHorizontalDragCancel: () => setState(() => _drag = null),
              child: WtFocusRing(
                show: _focused && _enabled,
                radius: 8,
                child: SizedBox(
                  height: 44,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _ScrubPainter(played: played, buffered: buffered),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScrubPainter extends CustomPainter {
  _ScrubPainter({required this.played, required this.buffered});
  final double played;
  final double buffered;

  @override
  void paint(Canvas canvas, Size size) {
    const track = 8.0;
    const thumb = 14.0;
    final left = thumb / 2;
    final width = size.width - thumb;
    final top = (size.height - track) / 2;
    RRect bar(double fraction) => RRect.fromLTRBR(
      left,
      top,
      left + width * fraction,
      top + track,
      const Radius.circular(track / 2),
    );
    canvas
      ..drawRRect(bar(1), Paint()..color = const Color(0x1AFFFFFF))
      ..drawRRect(bar(buffered), Paint()..color = const Color(0x38FFFFFF))
      ..drawRRect(bar(played), Paint()..color = WtColors.pink);
    final center = Offset(left + width * played, size.height / 2);
    canvas
      ..drawCircle(
        center.translate(0, 2),
        thumb / 2 + 1,
        Paint()
          ..color = const Color(0x66000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawCircle(center, thumb / 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ScrubPainter old) =>
      old.played != played || old.buffered != buffered;
}

class _StagePanel extends StatelessWidget {
  const _StagePanel({
    required this.outline,
    required this.tile,
    required this.title,
    required this.body,
    required this.action,
  });
  final Color outline;
  final Widget tile;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) => Container(
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
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: WtColors.tx3,
              ),
            ),
            const SizedBox(height: 20),
            action,
          ],
        ),
      ),
    ),
  );
}

class _GlowTile extends StatelessWidget {
  const _GlowTile({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 64,
    decoration: BoxDecoration(
      color: WtColors.s1,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: WtColors.line, width: 2),
      boxShadow: const [
        BoxShadow(color: Color(0x59D93583), blurRadius: 40, spreadRadius: 4),
      ],
    ),
    child: Center(child: child),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.notice});
  final PauseNotice notice;

  @override
  Widget build(BuildContext context) {
    final by = notice.by;
    return Container(
      height: 36,
      padding: EdgeInsets.only(left: by == null ? 12 : 4, right: 14),
      decoration: BoxDecoration(
        color: const Color(0xEB140A20),
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (by == null)
            const Icon(Icons.pause_rounded, size: 18, color: WtColors.tx2)
          else
            WtAvatar(id: by, name: by, size: 26, ring: const Color(0xEB140A20)),
          const SizedBox(width: 8),
          Text(
            by == null
                ? 'Paused · ${fmtTime(notice.positionMs)}'
                : 'Paused by ${by == 'You' ? 'you' : by} · ${fmtTime(notice.positionMs)}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: WtColors.text,
            ),
          ),
        ],
      ),
    );
  }
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
              Text(
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
