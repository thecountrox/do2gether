import 'package:flutter/material.dart';

import '../theme.dart';

class WtBackground extends StatelessWidget {
  const WtBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: WtColors.bg,
      gradient: RadialGradient(
        center: Alignment.topRight,
        radius: 1.6,
        colors: [Color(0x25FF7AB8), Color(0x00FF7AB8)],
        stops: [0, 1],
      ),
    ),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.bottomLeft,
          radius: 1.5,
          colors: [Color(0x1CC08CFF), Color(0x00C08CFF)],
          stops: [0, 1],
        ),
      ),
      child: child,
    ),
  );
}

class WtChip extends StatelessWidget {
  const WtChip({
    super.key,
    required this.label,
    this.onTap,
    this.color = WtColors.text,
    this.icon,
    this.tilt = 0,
  });
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final IconData? icon;
  final double tilt;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: tilt.clamp(-0.026, 0.026),
    child: Material(
       color: WtColors.surface,
      shape: const StadiumBorder(
        side: BorderSide(color: WtColors.highlight, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class WtSyncDot extends StatefulWidget {
  const WtSyncDot({super.key, required this.color, required this.connected});
  final Color color;
  final bool connected;

  @override
  State<WtSyncDot> createState() => _WtSyncDotState();
}

class _WtSyncDotState extends State<WtSyncDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    if (widget.connected) controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(WtSyncDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connected != oldWidget.connected) {
      if (widget.connected) {
        controller.repeat(reverse: true);
      } else {
        controller.stop();
        controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 1, end: 0.4).animate(controller),
    child: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
    ),
  );
}

class WtGlassBar extends StatelessWidget {
  const WtGlassBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x22FFFFFF), Color(0x14FFFFFF)],
      ),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: WtColors.stroke, width: 2),
      boxShadow: const [
        BoxShadow(
          color: Color(0x660A051A),
          blurRadius: 30,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: child,
  );
}

class WtSheet extends StatelessWidget {
  const WtSheet({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget child,
  }) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 240),
      reverseDuration: Duration(milliseconds: 240),
    ),
    builder: (_) => WtSheet(title: title, child: child),
  );

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    decoration: const BoxDecoration(
      color: WtColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      border: Border(
        top: BorderSide(color: WtColors.highlight, width: 2),
        left: BorderSide(color: WtColors.stroke, width: 2),
        right: BorderSide(color: WtColors.stroke, width: 2),
      ),
    ),
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: WtColors.muted,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 24),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class WtEmptyState extends StatelessWidget {
  const WtEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
    this.outlined = false,
  });
  final IconData icon;
  final String message;
  final Widget? action;
  final bool outlined;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: outlined
        ? BoxDecoration(
            border: Border.all(color: WtColors.accent),
            borderRadius: BorderRadius.circular(24),
          )
        : null,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [WtColors.cyan, WtColors.violet],
            ),
            boxShadow: [
              BoxShadow(
                color: WtColors.cyan.withValues(alpha: 0.5),
                blurRadius: 22,
              ),
            ],
          ),
          child: const Icon(Icons.add, size: 40, color: WtColors.bg),
        ),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (action != null) ...[const SizedBox(height: 24), action!],
      ],
    ),
  );
}

class WtCode extends StatelessWidget {
  const WtCode({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SelectableText(
        code,
        style: const TextStyle(
          fontFamily: 'Baloo2',
          fontSize: 40,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          color: WtColors.text,
        ),
      ),
      const SizedBox(height: 4),
      const Text(
        'SHARE THIS CODE',
        style: TextStyle(color: WtColors.muted, fontSize: 12, letterSpacing: 1),
      ),
    ],
  );
}

class WtBanner extends StatelessWidget {
  const WtBanner({
    super.key,
    required this.message,
    this.color = WtColors.danger,
  });
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: TextStyle(color: color, fontSize: 13)),
  );
}
