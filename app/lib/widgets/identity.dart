import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';

Color avatarColor(String id) {
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return [WtColors.pink, WtColors.cyan, WtColors.violet][hash % 3];
}

class WtAvatar extends StatelessWidget {
  const WtAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 36,
  });
  final String id;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: name,
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: WtColors.text, width: 2),
        gradient: LinearGradient(
          colors: switch (avatarColor(id)) {
            WtColors.pink => [WtColors.pink, WtColors.star],
            WtColors.cyan => [WtColors.cyan, WtColors.violet],
            _ => [WtColors.violet, WtColors.pink],
          },
        ),
      ),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(
          color: WtColors.text,
          fontSize: size * 0.4,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );
}

class WtAvatarStack extends StatelessWidget {
  const WtAvatarStack({super.key, required this.members});
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(4).toList();
    if (shown.isEmpty) {
      return const Icon(Icons.people_outline, color: WtColors.muted);
    }
    return SizedBox(
      width: 36 + (shown.length - 1) * 24.0,
      height: 38,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 24.0,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: WtColors.bg,
                ),
                child: WtAvatar(
                  id: shown[i].userId,
                  name: shown[i].name ?? shown[i].userId,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
