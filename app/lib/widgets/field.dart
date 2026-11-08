import 'package:flutter/material.dart';

import '../theme.dart';

class WtField extends StatefulWidget {
  const WtField({
    super.key,
    required this.controller,
    this.hint,
    this.icon,
    this.readOnly = false,
    this.onChanged,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String? hint;
  final IconData? icon;
  final bool readOnly;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<WtField> createState() => _WtFieldState();
}

class _WtFieldState extends State<WtField> {
  bool focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (value) => setState(() => focused = value),
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          const BoxShadow(
            color: Color(0x5509001A),
            blurRadius: 8,
            offset: Offset(0, 3),
            blurStyle: BlurStyle.inner,
          ),
          if (focused)
            BoxShadow(
              color: WtColors.cyan.withValues(alpha: 0.6),
              blurRadius: 2,
              spreadRadius: 2,
            ),
        ],
      ),
      child: TextField(
        controller: widget.controller,
        readOnly: widget.readOnly,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        style: const TextStyle(color: WtColors.text, fontSize: 15),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(color: WtColors.muted),
          prefixIcon: widget.icon == null
              ? null
              : Icon(widget.icon, color: WtColors.muted, size: 20),
          filled: true,
          fillColor: WtColors.surface2,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 18,
          ),
          constraints: const BoxConstraints(minHeight: 56),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: WtColors.stroke, width: 2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: WtColors.cyan.withValues(alpha: 0.6),
              width: 2,
            ),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
    ),
  );
}
