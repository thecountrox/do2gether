/// Player controls for the Room dock: seek bar, volume, track menu and the shortcut sheet.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';

/// The dock's labelled back/ahead buttons.
const int skipMs = 10000;

/// Arrow keys, on the room and on a focused seek bar.
const int arrowSeekMs = 5000;

/// Shift + arrow keys.
const int longSeekMs = 30000;

/// `1.25×`, `0.5×`, `1×`.
String fmtSpeed(double rate) {
  final s = rate.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  return '${s.endsWith('.') ? s.substring(0, s.length - 1) : s}×';
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);
  final int delta;
}

Map<ShortcutActivator, Intent> _arrowSteps(int step, int long) => {
  const SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-step),
  const SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(step),
  const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
      _StepIntent(-long),
  const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
      _StepIntent(long),
};

/// Thick seek bar: 8 px track, buffered range, hover preview with a time tip, pink fill,
/// 14 px handle, 44 px hit area. A drag commits one seek on release; a click seeks at once.
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
  static const _inset = _ScrubPainter.thumb / 2;

  double? _drag;
  double? _hover;
  bool _focused = false;

  int get _total => widget.durationMs;
  bool get _enabled => widget.onSeek != null && _total > 0;

  double _fraction(double dx, double width) => width <= 2 * _inset
      ? 0
      : ((dx - _inset) / (width - 2 * _inset)).clamp(0.0, 1.0);

  void _seekFraction(double f) => widget.onSeek?.call((f * _total).round());

  void _step(int delta) =>
      widget.onSeek?.call((widget.positionMs + delta).clamp(0, _total));

  @override
  Widget build(BuildContext context) {
    final pos = widget.positionMs.clamp(0, math.max<int>(0, _total));
    final played = _drag ?? (_total > 0 ? pos / _total : 0.0);
    final buffered = _total > 0
        ? (widget.bufferedMs / _total).clamp(0.0, 1.0)
        : 0.0;
    final pointer = _enabled ? (_drag ?? _hover) : null;
    return Semantics(
      slider: true,
      label: 'Seek',
      enabled: _enabled,
      value: fmtTimeWords(pos),
      increasedValue: fmtTimeWords(math.min(_total, pos + arrowSeekMs)),
      decreasedValue: fmtTimeWords(math.max(0, pos - arrowSeekMs)),
      onIncrease: _enabled ? () => _step(arrowSeekMs) : null,
      onDecrease: _enabled ? () => _step(-arrowSeekMs) : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: _arrowSteps(arrowSeekMs, longSeekMs),
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (i) {
              _step(i.delta);
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            double f(Offset p) => _fraction(p.dx, width);
            return MouseRegion(
              onHover: (e) {
                if (_enabled) setState(() => _hover = f(e.localPosition));
              },
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _enabled ? (d) => _seekFraction(f(d.localPosition)) : null,
                onHorizontalDragStart: _enabled
                    ? (d) => setState(() => _drag = f(d.localPosition))
                    : null,
                onHorizontalDragUpdate: _enabled
                    ? (d) => setState(() => _drag = f(d.localPosition))
                    : null,
                onHorizontalDragEnd: _enabled
                    ? (_) {
                        final at = _drag;
                        setState(() => _drag = null);
                        if (at != null) _seekFraction(at);
                      }
                    : null,
                onHorizontalDragCancel: () => setState(() => _drag = null),
                child: WtFocusRing(
                  show: _focused && _enabled,
                  radius: 8,
                  child: SizedBox(
                    height: 44,
                    width: double.infinity,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ScrubPainter(
                              played: played,
                              buffered: buffered,
                              preview: _drag == null ? pointer : null,
                            ),
                          ),
                        ),
                        if (pointer != null) ...[
                          Positioned(
                            left: _inset + (width - 2 * _inset) * pointer,
                            bottom: 44,
                            child: IgnorePointer(
                              child: FractionalTranslation(
                                translation: const Offset(-0.5, 0),
                                child: _TimeTip(
                                  fmtTime((pointer * _total).round()),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: IgnorePointer(
                              child: Text(
                                fmtRemaining(
                                  _drag == null
                                      ? pos
                                      : (_drag! * _total).round(),
                                  _total,
                                ),
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1,
                                  fontWeight: FontWeight.w800,
                                  color: WtColors.tx3,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
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

class _TimeTip extends StatelessWidget {
  const _TimeTip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFF120A1C),
      borderRadius: BorderRadius.circular(WtRadius.chip),
      border: Border.all(color: WtColors.line),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: WtColors.text,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _ScrubPainter extends CustomPainter {
  _ScrubPainter({
    required this.played,
    required this.buffered,
    this.preview,
    this.track = 8,
    this.fill = WtColors.pink,
  });
  static const double thumb = 14;
  final double played;
  final double buffered;
  final double? preview;
  final double track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final knob = track < 8 ? 12.0 : thumb;
    final left = knob / 2;
    final width = size.width - knob;
    final top = (size.height - track) / 2;
    RRect bar(double fraction) => RRect.fromLTRBR(
      left,
      top,
      left + width * fraction,
      top + track,
      Radius.circular(track / 2),
    );
    canvas
      ..drawRRect(bar(1), Paint()..color = const Color(0x1AFFFFFF))
      ..drawRRect(bar(buffered), Paint()..color = const Color(0x4DFFFFFF));
    if (preview case final p?) {
      canvas.drawRRect(bar(p), Paint()..color = fill.withValues(alpha: 0.35));
    }
    canvas.drawRRect(bar(played), Paint()..color = fill);
    final center = Offset(left + width * played, size.height / 2);
    canvas
      ..drawCircle(
        center.translate(0, 2),
        knob / 2 + 1,
        Paint()
          ..color = const Color(0x66000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawCircle(center, knob / 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ScrubPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.preview != preview ||
      old.fill != fill;
}

/// Mute button whose level slider slides out on hover or keyboard focus. Muted reads yellow.
class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    required this.volume,
    required this.muted,
    this.onToggleMute,
    this.onVolume,
  });

  /// 0–100.
  final double volume;
  final bool muted;
  final VoidCallback? onToggleMute;
  final ValueChanged<double>? onVolume;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  static const _slider = 104.0;
  bool _hover = false;
  bool _focus = false;

  bool get _open => (_hover || _focus) && widget.onVolume != null;

  @override
  Widget build(BuildContext context) {
    final silent = widget.muted || widget.volume <= 0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (v) => setState(() => _focus = v),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            WtIconButton(
              icon: silent
                  ? Icons.volume_off_rounded
                  : widget.volume < 50
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
              tooltip: widget.muted ? 'Unmute (M)' : 'Mute (M)',
              iconColor: widget.muted ? WtColors.yellow : WtColors.text,
              background: widget.muted ? const Color(0x1FFFD45E) : WtColors.s1,
              onPressed: widget.onToggleMute,
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(end: _open ? _slider + 8 : 0),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              builder: (context, width, child) => SizedBox(
                width: width,
                height: 44,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerRight,
                    minWidth: _slider + 8,
                    maxWidth: _slider + 8,
                    child: child,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _VolumeSlider(
                  value: widget.muted ? 0 : widget.volume,
                  dimmed: widget.muted,
                  onChanged: widget.onVolume,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({
    required this.value,
    required this.dimmed,
    required this.onChanged,
  });
  final double value;
  final bool dimmed;
  final ValueChanged<double>? onChanged;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  bool _focused = false;

  void _set(double v) => widget.onChanged?.call(v.clamp(0, 100).roundToDouble());

  void _at(Offset p, double width) => _set(
    width <= 12 ? 0 : (p.dx - 6) / (width - 12) * 100,
  );

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Semantics(
      slider: true,
      label: 'Volume',
      value: '${widget.value.round()}%',
      enabled: enabled,
      onIncrease: enabled ? () => _set(widget.value + 10) : null,
      onDecrease: enabled ? () => _set(widget.value - 10) : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: _arrowSteps(10, 50),
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (i) {
              _set(widget.value + i.delta);
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: enabled ? (d) => _at(d.localPosition, box.maxWidth) : null,
            onHorizontalDragUpdate: enabled
                ? (d) => _at(d.localPosition, box.maxWidth)
                : null,
            child: WtFocusRing(
              show: _focused,
              radius: 8,
              child: SizedBox(
                height: 44,
                width: double.infinity,
                child: CustomPaint(
                  painter: _ScrubPainter(
                    played: widget.value / 100,
                    buffered: 0,
                    track: 6,
                    fill: widget.dimmed ? WtColors.tx3 : WtColors.pink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One audio or subtitle track as the player reports it.
typedef TrackOption = ({String id, String label, bool active});

/// Audio and subtitle picker. Hidden by the dock when there is nothing to choose.
class TrackMenu extends StatelessWidget {
  const TrackMenu({
    super.key,
    required this.audio,
    required this.subtitles,
    this.onAudio,
    this.onSubtitle,
  });
  final List<TrackOption> audio;

  /// Includes `Off`.
  final List<TrackOption> subtitles;
  final ValueChanged<String>? onAudio;
  final ValueChanged<String>? onSubtitle;

  /// True when the player reported more than one way to listen or any subtitles.
  static bool hasChoice(List<TrackOption> audio, List<TrackOption> subtitles) =>
      audio.length > 1 || subtitles.any((t) => t.id != 'no');

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(WtColors.plum2),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WtRadius.control),
          side: const BorderSide(color: WtColors.line, width: 2),
        ),
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
    ),
    builder: (context, controller, _) => WtIconButton(
      icon: Icons.subtitles_rounded,
      tooltip: 'Audio and subtitles',
      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
    ),
    menuChildren: [
      if (audio.isNotEmpty) ...[
        const _MenuLabel('Audio'),
        for (final t in audio) _TrackItem(track: t, onPick: onAudio),
      ],
      if (subtitles.isNotEmpty) ...[
        const _MenuLabel('Subtitles'),
        for (final t in subtitles) _TrackItem(track: t, onPick: onSubtitle),
      ],
    ],
  );
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
    child: WtLabel(text),
  );
}

class _TrackItem extends StatelessWidget {
  const _TrackItem({required this.track, required this.onPick});
  final TrackOption track;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    onPressed: onPick == null ? null : () => onPick!(track.id),
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(240, 40)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
            ? WtColors.s2
            : null,
      ),
      foregroundColor: const WidgetStatePropertyAll(WtColors.text),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'MPlusRounded',
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    leadingIcon: SizedBox(
      width: 20,
      child: track.active
          ? const Icon(Icons.check_rounded, size: 18, color: WtColors.pink)
          : null,
    ),
    semanticsLabel: track.active ? '${track.label}, selected' : track.label,
    child: Text(track.label),
  );
}

/// A keyboard key, for the shortcut sheet. Room codes are not keys and do not use this.
class WtKey extends StatelessWidget {
  const WtKey(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 30),
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: WtColors.plum,
      borderRadius: BorderRadius.circular(8),
      border: const Border(
        left: BorderSide(color: WtColors.line, width: 2),
        top: BorderSide(color: WtColors.line, width: 2),
        right: BorderSide(color: WtColors.line, width: 2),
        bottom: BorderSide(color: WtColors.line, width: 4),
      ),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 13,
        height: 1,
        fontWeight: FontWeight.w900,
        color: WtColors.text,
      ),
    ),
  );
}

const List<(List<String>, String)> roomShortcuts = [
  (['Space'], 'Play or pause, for everyone'),
  (['←', '→'], 'Back or ahead 5 seconds'),
  (['Shift', '←', '→'], 'Back or ahead 30 seconds'),
  (['F'], 'Fullscreen'),
  (['M'], 'Mute'),
  (['Esc'], 'Leave fullscreen'),
  (['?'], 'This sheet'),
];

Future<void> showShortcutSheet(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x8C000000),
  builder: (_) => const ShortcutSheet(),
);

class ShortcutSheet extends StatelessWidget {
  const ShortcutSheet({super.key});

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: WtColors.plum2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(WtRadius.surface),
      side: const BorderSide(color: WtColors.line, width: 2),
    ),
    child: SizedBox(
      width: 420,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Keyboard shortcuts',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Play, pause and seeking move the whole room.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            for (final (keys, what) in roomShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 150,
                      child: Wrap(
                        spacing: 4,
                        children: [for (final k in keys) WtKey(k)],
                      ),
                    ),
                    Expanded(
                      child: Text(
                        what,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: WtColors.tx2,
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
