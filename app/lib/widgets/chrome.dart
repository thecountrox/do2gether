import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';

/// Window background: base colour, pink glow top-right, violet glow bottom-left, dot grid.
class WtBackdrop extends StatelessWidget {
  const WtBackdrop({
    super.key,
    required this.child,
    this.color = WtColors.plum,
    this.grid = 22,
  });
  final Widget child;
  final Color color;
  final double grid;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.86, -0.9),
              radius: 0.75,
              colors: [Color(0x38D93583), Color(0x00D93583)],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.92, 0.86),
              radius: 0.75,
              colors: [Color(0x336A45F2), Color(0x006A45F2)],
            ),
          ),
        ),
        RepaintBoundary(child: CustomPaint(painter: _DotGrid(grid))),
        child,
      ],
    ),
  );
}

class _DotGrid extends CustomPainter {
  _DotGrid(this.step);
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x0DFFE8F8);
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGrid old) => old.step != step;
}

/// The tilted gradient tile with two play triangles.
class WtMark extends StatelessWidget {
  const WtMark({super.key, this.size = 42});
  final double size;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -8 * math.pi / 180,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: WtColors.grad,
        borderRadius: BorderRadius.circular(size / 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0xCCE23A96),
            offset: Offset(0, 6),
            blurRadius: 16,
            spreadRadius: -6,
          ),
        ],
      ),
      child: CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 42;
    Path tri(double left) => Path()
      ..moveTo(left * u, 13 * u)
      ..lineTo((left + 12) * u, 21 * u)
      ..lineTo(left * u, 29 * u)
      ..close();
    canvas
      ..drawPath(tri(10), Paint()..color = const Color(0x8CFFFFFF))
      ..drawPath(tri(17), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WtWordmark extends StatelessWidget {
  const WtWordmark({super.key, this.size = 22, this.mark = 42});
  final double size;
  final double mark;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'watch together',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WtMark(size: mark),
        SizedBox(width: mark * 0.29),
        Text.rich(
          TextSpan(
            children: const [
              TextSpan(text: 'watch'),
              TextSpan(
                text: '·',
                style: TextStyle(color: WtColors.pink),
              ),
              TextSpan(text: 'together'),
            ],
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.01 * size,
              color: WtColors.text,
            ),
          ),
          maxLines: 1,
        ),
      ],
    ),
  );
}

class WtGradientText extends StatelessWidget {
  const WtGradientText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: WtColors.gradText.createShader,
    child: Text(text, style: style),
  );
}

enum WtKeySize { small, medium, large }

/// The room code as keyboard caps, split in two groups with a dash.
class WtKeyCaps extends StatelessWidget {
  const WtKeyCaps({super.key, required this.code, this.size = WtKeySize.medium});
  final String code;
  final WtKeySize size;

  @override
  Widget build(BuildContext context) {
    final groups = codeGroups(code);
    final large = size == WtKeySize.large;
    final gap = large ? 8.0 : 4.0;
    final children = <Widget>[];
    var index = 0;
    for (var g = 0; g < groups.length; g++) {
      if (g > 0) {
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gap / 2 + 2),
            child: Container(
              width: large ? 14 : 8,
              height: large ? 4 : 3,
              decoration: BoxDecoration(
                color: WtColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      }
      for (var i = 0; i < groups[g].length; i++) {
        if (i > 0) children.add(SizedBox(width: gap));
        children.add(_Cap(groups[g][i], size, raised: index.isOdd));
        index++;
      }
    }
    return Semantics(
      label: 'Room code ${code.toUpperCase().split('').join(' ')}',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          // Room for the raised large caps.
          padding: EdgeInsets.only(top: large ? 3 : 0),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

class _Cap extends StatelessWidget {
  const _Cap(this.char, this.size, {required this.raised});
  final String char;
  final WtKeySize size;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final (w, h, r, font, strip) = switch (size) {
      WtKeySize.small => (24.0, 32.0, WtRadius.chip, 15.0, 0.0),
      WtKeySize.medium => (28.0, 36.0, 9.0, 17.0, 3.0),
      WtKeySize.large => (56.0, 70.0, 17.0, 34.0, 5.0),
    };
    final large = size == WtKeySize.large;
    final cap = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: large ? null : (strip == 0 ? WtColors.plum : WtColors.plum2),
        gradient: large
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2E1A48), WtColors.plum],
                stops: [0, 0.7],
              )
            : null,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: WtColors.line, width: 2),
        boxShadow: large
            ? const [
                BoxShadow(
                  color: Color(0xCC000000),
                  offset: Offset(0, 10),
                  blurRadius: 18,
                  spreadRadius: -10,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r - 2),
        child: Stack(
          children: [
            if (strip > 0)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: strip,
                child: const DecoratedBox(
                  decoration: BoxDecoration(gradient: WtColors.grad),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: large ? 6 : 3,
              child: const ColoredBox(color: Color(0x59000000)),
            ),
            Center(
              child: Text(
                char.toUpperCase(),
                style: TextStyle(
                  fontSize: font,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  color: WtColors.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return large && raised
        ? Transform.translate(offset: const Offset(0, -3), child: cap)
        : cap;
  }
}

enum WtTone { live, warn, neutral, quiet }

enum WtDotStyle { none, solid, ring, pulse }

/// Board `.chip` family: live (cyan), warn (yellow, dashed), neutral, quiet (dashed, muted).
class WtPill extends StatelessWidget {
  const WtPill({
    super.key,
    required this.label,
    this.tone = WtTone.neutral,
    this.dot = WtDotStyle.none,
    this.height = 32,
    this.fontSize = 14,
    this.icon,
  });
  final String label;
  final WtTone tone;
  final WtDotStyle dot;
  final double height;
  final double fontSize;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (fg, border, bg, dashed) = switch (tone) {
      WtTone.live => (
        WtColors.cyan,
        const Color(0x7362EAF4),
        const Color(0x1A62EAF4),
        false,
      ),
      WtTone.warn => (
        WtColors.yellow,
        const Color(0x99FFD45E),
        const Color(0x12FFD45E),
        true,
      ),
      WtTone.neutral => (WtColors.text, WtColors.line, WtColors.s1, false),
      WtTone.quiet => (WtColors.tx3, WtColors.line, WtColors.s1, true),
    };
    final content = Container(
      constraints: BoxConstraints(minHeight: height),
      padding: EdgeInsets.symmetric(horizontal: height >= 36 ? 16 : 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: dashed ? null : Border.all(color: border, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 7),
          ] else if (dot != WtDotStyle.none) ...[
            WtDot(color: fg, style: dot),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
    return dashed
        ? WtDashed(color: border, radius: WtRadius.pill, child: content)
        : content;
  }
}

/// 8px status dot. `pulse` rings three times then rests (board `.dot.p`).
class WtDot extends StatefulWidget {
  const WtDot({super.key, required this.color, this.style = WtDotStyle.solid});
  final Color color;
  final WtDotStyle style;

  @override
  State<WtDot> createState() => _WtDotState();
}

class _WtDotState extends State<WtDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started &&
        widget.style == WtDotStyle.pulse &&
        !MediaQuery.of(context).disableAnimations) {
      _started = true;
      _pulse.repeat(count: 3);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = widget.style == WtDotStyle.ring;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = _pulse.isAnimating
            ? (_pulse.value / 0.8).clamp(0.0, 1.0)
            : 1.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ring ? null : widget.color,
            border: ring ? Border.all(color: widget.color, width: 2) : null,
            boxShadow: t < 1
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.6 * (1 - t)),
                      spreadRadius: 7 * t,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// 2px dashed rounded outline drawn over [child].
class WtDashed extends StatelessWidget {
  const WtDashed({
    super.key,
    required this.child,
    required this.color,
    required this.radius,
  });
  final Widget child;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _DashPainter(color, radius),
    child: child,
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1);
    final r = math.min(radius, rect.shortestSide / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 6, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) =>
      old.color != color || old.radius != radius;
}

/// Uppercase section label with an optional right-hand note.
class WtLabel extends StatelessWidget {
  const WtLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text.toUpperCase(),
      maxLines: 1,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.96,
        color: WtColors.tx3,
      ),
    );
    if (trailing == null) return label;
    return Row(
      children: [
        Expanded(child: label),
        trailing!,
      ],
    );
  }
}

/// Calm inline notice (board `.alert.neutral`).
class WtAlert extends StatelessWidget {
  const WtAlert({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.iconColor = WtColors.tx3,
    this.actions = const [],
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: WtColors.plum,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: WtColors.line, width: 2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w800,
                  color: WtColors.text,
                ),
              ),
            ),
          ],
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 6),
            child: Text(
              body!,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w500,
                color: WtColors.tx3,
              ),
            ),
          ),
        for (final action in actions)
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 12),
            child: action,
          ),
      ],
    ),
  );
}

/// One-line file name truncated in the middle, so the distinguishing tail stays visible.
class WtMidText extends StatelessWidget {
  const WtMidText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final (head, tail) = splitTail(text);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                head,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.6),
              child: Text(
                tail,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Board `.fg` / `.ftile`: a file with a play mark.
class WtFileGlyph extends StatelessWidget {
  const WtFileGlyph({super.key, this.size = 28, this.color = WtColors.tx3});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.video_file_outlined, size: size, color: color);
}

/// Yellow four-point spark with a soft glow.
class WtSpark extends StatelessWidget {
  const WtSpark({super.key, this.size = 14, this.color = WtColors.yellow});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(size: Size.square(size), painter: _SparkPainter(color)),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * .5, 0)
      ..lineTo(w * .61, h * .39)
      ..lineTo(w, h * .5)
      ..lineTo(w * .61, h * .61)
      ..lineTo(w * .5, h)
      ..lineTo(w * .39, h * .61)
      ..lineTo(0, h * .5)
      ..lineTo(w * .39, h * .39)
      ..close();
    canvas
      ..drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      )
      ..drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.color != color;
}
