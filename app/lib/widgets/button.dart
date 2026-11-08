import 'package:flutter/material.dart';

import '../theme.dart';

enum WtButtonStyle { filled, ghost, danger }

enum WtButtonSize { regular, small }

class WtButton extends StatefulWidget {
  const WtButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.style = WtButtonStyle.filled,
    this.size = WtButtonSize.regular,
    this.fullWidth = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final WtButtonStyle style;
  final WtButtonSize size;
  final bool fullWidth;

  @override
  State<WtButton> createState() => _WtButtonState();
}

class _WtButtonState extends State<WtButton> {
  bool pressed = false;
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final filled = widget.style != WtButtonStyle.ghost;
    final radius = BorderRadius.circular(20);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() {
        hovered = false;
        pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => pressed = false) : null,
        onTapCancel: () => setState(() => pressed = false),
        child: AnimatedScale(
          scale: pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 120),
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: filled
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: widget.style == WtButtonStyle.danger
                            ? [WtColors.danger, WtColors.pink]
                            : [WtColors.pink, const Color(0xFFA66BFF)],
                      )
                    : LinearGradient(
                        colors: [
                          WtColors.surface2,
                          hovered
                              ? const Color(0x20FFFFFF)
                              : const Color(0x10FFFFFF),
                        ],
                      ),
                border: filled
                    ? null
                    : Border.all(color: const Color(0x2BFFFFFF), width: 2),
                boxShadow: filled
                    ? [
                        BoxShadow(
                          color: WtColors.pink.withValues(
                            alpha: hovered ? 0.42 : 0.28,
                          ),
                          blurRadius: 22,
                          offset: const Offset(0, 7),
                        ),
                      ]
                    : null,
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: radius,
                child: InkWell(
                  borderRadius: radius,
                  onTap: widget.onPressed,
                  child: Container(
                    height: widget.size == WtButtonSize.regular ? 56 : 44,
                    width: widget.fullWidth ? double.infinity : null,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    alignment: Alignment.center,
                    foregroundDecoration: filled
                        ? BoxDecoration(
                            borderRadius: radius,
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.center,
                              colors: [Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                            ),
                          )
                        : null,
                    child: Row(
                      mainAxisSize: widget.fullWidth
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: filled ? WtColors.bg : WtColors.text,
                          ),
                        ),
                      ],
                    ),
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
