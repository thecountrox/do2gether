import 'package:flutter/material.dart';

import '../theme.dart';

/// Board `.field`: plum well, 2px line, leading icon, optional trailing action.
class WtField extends StatefulWidget {
  const WtField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint,
    this.icon,
    this.iconColor = WtColors.pink,
    this.trailing,
    this.readOnly = false,
    this.autofocus = false,
    this.obscure = false,
    this.height = 60,
    this.onChanged,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;
  final IconData? icon;
  final Color iconColor;
  final Widget? trailing;
  final bool readOnly;
  final bool autofocus;

  /// Password entry: dots instead of text.
  final bool obscure;
  final double height;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<WtField> createState() => _WtFieldState();
}

class _WtFieldState extends State<WtField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) => setState(() => _focused = value),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      constraints: BoxConstraints(minHeight: widget.height),
      padding: EdgeInsets.only(
        left: 16,
        right: widget.trailing == null ? 16 : 6,
      ),
      decoration: BoxDecoration(
        color: WtColors.plum,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _focused ? WtColors.cyan : WtColors.line,
          width: 2,
        ),
      ),
      child: Row(
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 22, color: widget.iconColor),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              readOnly: widget.readOnly,
              autofocus: widget.autofocus,
              obscureText: widget.obscure,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              maxLines: 1,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: widget.readOnly ? WtColors.tx3 : WtColors.text,
              ),
              decoration: InputDecoration.collapsed(
                hintText: widget.hint,
                hintStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: WtColors.tx3,
                ),
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 10),
            widget.trailing!,
          ],
        ],
      ),
    ),
  );
}
