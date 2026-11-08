import 'package:flutter/material.dart';

abstract final class WtColors {
  static const bg = Color(0xFF1E1029);
  static const surface = Color(0xFF2B1838);
  static const surface2 = Color(0xFF3A2149);
  static const stroke = Color(0xFF5A3870);
  static const highlight = Color(0xFF6E4C84);
  static const text = Color(0xFFFFF4FB);
  static const helper = Color(0xFFEBDDF2);
  static const muted = Color(0xFFCDB8D8);
  static const pink = Color(0xFFFF7AB8);
  static const violet = Color(0xFFC08CFF);
  static const cyan = Color(0xFF5EF0E6);
  static const star = Color(0xFFFFE066);
  static const accent = pink;
  static const live = cyan;
  static const warn = star;
  static const danger = Color(0xFFFF766F);
  static const candy = LinearGradient(colors: [pink, Color(0xFFE58BE0), violet]);
}

ThemeData wtTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  fontFamily: 'MPlusRounded',
  scaffoldBackgroundColor: WtColors.bg,
  colorScheme: const ColorScheme.dark(
    primary: WtColors.pink,
    secondary: WtColors.cyan,
    surface: WtColors.surface,
    error: WtColors.danger,
    onPrimary: WtColors.bg,
    onSurface: WtColors.text,
  ),
  textTheme: const TextTheme(
    displayLarge: TextStyle(
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
      color: WtColors.text,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      height: 1.25,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      color: WtColors.text,
    ),
    bodyMedium: TextStyle(
      fontSize: 15,
      height: 1.47,
      fontWeight: FontWeight.w500,
      color: WtColors.text,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      height: 1.33,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.44,
      color: WtColors.muted,
    ),
  ),
  splashFactory: InkRipple.splashFactory,
);

class WtScaffold extends StatelessWidget {
  const WtScaffold({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: WtColors.bg,
    body: SafeArea(child: child),
  );
}

Route<void> wtRoute(Widget screen) => PageRouteBuilder<void>(
  transitionDuration: const Duration(milliseconds: 220),
  reverseTransitionDuration: const Duration(milliseconds: 220),
  pageBuilder: (_, _, _) => screen,
  transitionsBuilder: (_, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.02),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);
