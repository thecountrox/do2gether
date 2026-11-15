import 'package:flutter/material.dart';

import '../theme.dart';

/// Cyan 2px ring, 3px outside the child, while keyboard focus is on it.
class WtFocusRing extends StatelessWidget {
  const WtFocusRing({
    super.key,
    required this.show,
    required this.radius,
    required this.child,
  });
  final bool show;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      if (show)
        Positioned(
          left: -5,
          top: -5,
          right: -5,
          bottom: -5,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius + 5),
                border: Border.all(color: WtColors.cyan, width: 2),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Shared interaction for every tappable surface: click cursor, Enter activates,
/// pressed scale .96 over 120 ms, focus ring, 40% when disabled.
class WtTap extends StatefulWidget {
  const WtTap({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = WtRadius.control,
    this.tooltip,
    this.semanticLabel,
    this.dimWhenDisabled = true,
  });
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final String? tooltip;
  final String? semanticLabel;
  final bool dimWhenDisabled;

  @override
  State<WtTap> createState() => _WtTapState();
}

class _WtTapState extends State<WtTap> {
  bool _focused = false;
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget child = FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _press(true) : null,
        onTapUp: enabled ? (_) => _press(false) : null,
        onTapCancel: () => _press(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: WtFocusRing(
            show: _focused && enabled,
            radius: widget.radius,
            child: widget.child,
          ),
        ),
      ),
    );
    child = Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: child,
    );
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, child: child);
    }
    return widget.dimWhenDisabled && !enabled
        ? Opacity(opacity: 0.4, child: child)
        : child;
  }
}

/// Board `.btn-primary` inset: `inset 0 1.5px 0 rgba(255,255,255,.55)`.
class WtInsetHighlight extends StatelessWidget {
  const WtInsetHighlight({super.key, required this.radius, required this.child});
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x8CFFFFFF), width: 1.5)),
      ),
      child: child,
    ),
  );
}

enum WtButtonStyle { primary, ghost }

enum WtButtonSize { large, medium, small }

class WtButton extends StatelessWidget {
  const WtButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
    this.style = WtButtonStyle.primary,
    this.size = WtButtonSize.medium,
    this.fullWidth = false,
    this.tooltip,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailingIcon;
  final WtButtonStyle style;
  final WtButtonSize size;
  final bool fullWidth;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final primary = style == WtButtonStyle.primary;
    final (height, radius, font, pad) = switch (size) {
      WtButtonSize.large => (60.0, 20.0, 17.0, 24.0),
      WtButtonSize.medium => (48.0, WtRadius.control, 15.0, 18.0),
      WtButtonSize.small => (40.0, 14.0, 14.0, 14.0),
    };
    final content = Container(
      height: height,
      width: fullWidth ? double.infinity : null,
      padding: EdgeInsets.symmetric(horizontal: pad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: primary ? WtColors.grad : null,
        color: primary ? null : WtColors.s2,
        border: Border.all(
          color: primary ? const Color(0x3DFFFFFF) : WtColors.line,
          width: 2,
        ),
        boxShadow: primary && onPressed != null ? WtColors.glow : null,
      ),
      child: Row(
        mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: font + 3, color: WtColors.text),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: font,
                fontWeight: FontWeight.w800,
                color: WtColors.text,
              ),
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 10),
            Icon(trailingIcon, size: font + 5, color: WtColors.text),
          ],
        ],
      ),
    );
    return WtTap(
      onTap: onPressed,
      radius: radius,
      tooltip: tooltip,
      child: primary ? WtInsetHighlight(radius: radius, child: content) : content,
    );
  }
}

/// Square 44 icon button, board `.icon-btn`.
class WtIconButton extends StatelessWidget {
  const WtIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.background = WtColors.s1,
    this.iconColor = WtColors.text,
    this.semanticLabel,
    this.dimWhenDisabled = true,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color background;
  final Color iconColor;
  final String? semanticLabel;
  final bool dimWhenDisabled;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onPressed,
    tooltip: tooltip,
    semanticLabel: semanticLabel ?? tooltip,
    dimWhenDisabled: dimWhenDisabled,
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(WtRadius.control),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Icon(icon, size: 22, color: iconColor),
    ),
  );
}

/// Pink text action, board `.txt-btn`.
class WtTextButton extends StatelessWidget {
  const WtTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = WtColors.pink,
    this.compact = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onPressed,
    radius: 14,
    child: Container(
      constraints: BoxConstraints(minHeight: compact ? 32 : 44),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: compact ? 14 : 15,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    ),
  );
}
