import 'package:flutter/material.dart';

/// Tokens from the approved boards (docs/design/*.html, TASK15.md).
abstract final class WtColors {
  static const board = Color(0xFF0C0613);
  static const plum = Color(0xFF1A0E27);

  /// Board `--plum-2`: bars, rail, dock, key caps, dialog.
  static const plum2 = Color(0xFF22133A);
  static const s1 = Color(0xFF2B1945);
  static const s2 = Color(0xFF362056);
  static const line = Color(0x33FFE8F8);
  static const text = Color(0xFFFFF4FB);
  static const tx2 = Color(0xFFEBDDF2);
  static const tx3 = Color(0xFFD4C0E2);

  /// Board `--pink`: text buttons, scrubber fill, step/now-playing accents.
  static const pink = Color(0xFFFF5FAE);

  /// Live and sync only.
  static const cyan = Color(0xFF62EAF4);

  /// Tiny accents: sparks, "not everyone is ready", waiting.
  static const yellow = Color(0xFFFFD45E);
  static const danger = Color(0xFFFF6B6B);

  static const grad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFD93583), Color(0xFFA63AC6), Color(0xFF6A45F2)],
    stops: [0, 0.52, 1],
  );

  /// Board `--grad-text`, for gradient headline words.
  static const gradText = LinearGradient(
    colors: [Color(0xFFFF8CC8), Color(0xFFB79AFF)],
  );

  /// `0 12px 30px -10px rgba(226,58,150,.75), 0 4px 18px -8px rgba(110,70,240,.6)`.
  static const glow = [
    BoxShadow(
      color: Color(0xBFE23A96),
      offset: Offset(0, 12),
      blurRadius: 30,
      spreadRadius: -10,
    ),
    BoxShadow(
      color: Color(0x996E46F0),
      offset: Offset(0, 4),
      blurRadius: 18,
      spreadRadius: -8,
    ),
  ];
}

abstract final class WtRadius {
  static const double chip = 10;
  static const double control = 16;
  static const double surface = 24;
  static const double pill = 999;
}

abstract final class WtSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double window = 24;
  static const double rail = 16;
}

/// Below this window width Home stacks into one column and Room hides its rail behind a button.
/// Tiling compositors (Hyprland) ignore the runner's min-size hint, so this has to hold.
const double wtCompactWidth = 1024;

ThemeData wtTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  fontFamily: 'MPlusRounded',
  scaffoldBackgroundColor: WtColors.plum,
  colorScheme: const ColorScheme.dark(
    primary: WtColors.pink,
    secondary: WtColors.cyan,
    surface: WtColors.s1,
    error: WtColors.danger,
    onPrimary: WtColors.text,
    onSurface: WtColors.text,
  ),
  textTheme: const TextTheme(
    displayLarge: TextStyle(
      fontSize: 46,
      height: 1.04,
      fontWeight: FontWeight.w900,
      letterSpacing: -1.15,
      color: WtColors.text,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      height: 1.15,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.4,
      color: WtColors.text,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      height: 1.25,
      fontWeight: FontWeight.w900,
      color: WtColors.text,
    ),
    bodyMedium: TextStyle(
      fontSize: 15,
      height: 1.5,
      fontWeight: FontWeight.w500,
      color: WtColors.text,
    ),
    bodySmall: TextStyle(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w500,
      color: WtColors.tx3,
    ),
    labelSmall: TextStyle(
      fontSize: 12,
      height: 1.3,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.96,
      color: WtColors.tx2,
    ),
  ),
  tooltipTheme: TooltipThemeData(
    waitDuration: const Duration(milliseconds: 400),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    textStyle: const TextStyle(
      fontFamily: 'MPlusRounded',
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: WtColors.text,
    ),
    decoration: BoxDecoration(
      color: const Color(0xFF120A1C),
      borderRadius: BorderRadius.circular(WtRadius.chip),
      border: Border.all(color: WtColors.line),
    ),
  ),
  textSelectionTheme: const TextSelectionThemeData(
    cursorColor: WtColors.cyan,
    selectionColor: Color(0x5562EAF4),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: WtColors.s2,
    contentTextStyle: const TextStyle(
      fontFamily: 'MPlusRounded',
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: WtColors.text,
    ),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(WtRadius.control),
    ),
  ),
  splashFactory: NoSplash.splashFactory,
  highlightColor: Colors.transparent,
  hoverColor: Colors.transparent,
);

class WtScaffold extends StatelessWidget {
  const WtScaffold({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: WtColors.plum,
    body: SafeArea(child: child),
  );
}

Route<T> wtRoute<T>(Widget screen) => PageRouteBuilder<T>(
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
