import 'package:flutter/material.dart';

import '../theme.dart';

/// Board avatars: `.av-a` pink, `.av-b` violet, `.av-c` light.
enum _Swatch { pink, violet, light }

_Swatch _swatch(String id) {
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return _Swatch.values[hash % 3];
}

class WtAvatar extends StatelessWidget {
  const WtAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 36,
    this.ring = WtColors.plum2,
    this.muted = false,
  });
  final String id;
  final String name;
  final double size;
  final Color ring;

  /// Board `.av-d`: someone not ready yet.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final swatch = _swatch(id);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 2),
        color: muted
            ? WtColors.s2
            : swatch == _Swatch.light
            ? const Color(0xFFFFE6F3)
            : null,
        gradient: muted
            ? null
            : switch (swatch) {
                _Swatch.pink => const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFF92C9), Color(0xFFD93583)],
                ),
                _Swatch.violet => const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFB49BFF), Color(0xFF6A45F2)],
                ),
                _Swatch.light => null,
              },
      ),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
        style: TextStyle(
          color: muted
              ? WtColors.tx3
              : swatch == _Swatch.light
              ? const Color(0xFF4A1F55)
              : Colors.white,
          fontSize: size * 0.4,
          height: 1,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/// Overlapping avatars, board `.stack`; extra people collapse into `+N`.
class WtAvatarStack extends StatelessWidget {
  const WtAvatarStack({
    super.key,
    required this.people,
    this.extra = 0,
    this.size = 30,
    this.ring = WtColors.plum,
  });

  /// `(id, name)` pairs.
  final List<(String, String)> people;
  final int extra;
  final double size;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(3).toList();
    final more = extra + people.length - shown.length;
    final count = shown.length + (more > 0 ? 1 : 0);
    if (count == 0) return const SizedBox.shrink();
    final step = size - 8;
    return SizedBox(
      width: size + (count - 1) * step,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: WtAvatar(
                id: shown[i].$1,
                name: shown[i].$2,
                size: size,
                ring: ring,
              ),
            ),
          if (more > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: WtColors.s2,
                  border: Border.all(color: ring, width: 2),
                ),
                child: Text(
                  '+$more',
                  style: TextStyle(
                    fontSize: size * 0.36,
                    fontWeight: FontWeight.w900,
                    color: WtColors.tx2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
