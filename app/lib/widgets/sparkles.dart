import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A non-interactive, deterministic backdrop; place only behind UI chrome.
class WtSparkles extends StatefulWidget {
  const WtSparkles({super.key, this.seed = 'watch together'});
  final String seed;

  @override
  State<WtSparkles> createState() => _WtSparklesState();
}

class _WtSparklesState extends State<WtSparkles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _drift.stop();
      _drift.value = 0;
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _StarPainter(widget.seed, _drift),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.seed, this.drift) : super(repaint: drift);
  final String seed;
  final Animation<double> drift;

  @override
  void paint(Canvas canvas, Size size) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final random = math.Random(hash);
    for (var i = 0; i < 10; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final radius = 2.5 + random.nextDouble() * 3.5;
      final phase = random.nextDouble() * math.pi * 2;
      final star = Path();
      final dy = math.sin(drift.value * math.pi * 2 + phase) * 7;
      final dx = math.cos(drift.value * math.pi * 2 + phase) * 4;
      for (var point = 0; point < 8; point++) {
        final angle = point * math.pi / 4;
        final r = point.isEven ? radius : radius * 0.25;
        final px = x + dx + math.cos(angle) * r;
        final py = y + dy + math.sin(angle) * r;
        if (point == 0) {
          star.moveTo(px, py);
        } else {
          star.lineTo(px, py);
        }
      }
      star.close();
      canvas.drawPath(
        star,
        Paint()
          ..color = (i.isEven ? WtColors.star : WtColors.text).withValues(
            alpha: 0.2 + random.nextDouble() * 0.25,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StarPainter oldDelegate) =>
      oldDelegate.seed != seed;
}
