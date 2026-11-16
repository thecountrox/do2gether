import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_screen.dart';
import 'links.dart';
import 'scheme_install.dart';
import 'single_instance.dart';
import 'theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final invite = inviteFromArgs(args);
  final libraryTab = librarySource(args);
  final openLibrary = wantsLibrary(args);
  final instance = SingleInstance.fromEnvironment();

  if (!kIsWeb && !await instance.claim()) {
    // Another window owns the app: hand it the invite and leave, instead of opening a second one.
    await instance.forward(invite);
    exit(0);
  }

  // Tarball and zip builds have no installer, so the app claims the invite scheme itself.
  if (!kIsWeb) {
    unawaited(
      ensureInviteScheme(
        executable: Platform.resolvedExecutable,
        home: Platform.environment['HOME'] ?? '',
      ),
    );
  }

  runApp(WatchTogetherApp(
    invite: invite,
    invites: instance.invites,
    openLibrary: openLibrary,
    libraryTab: libraryTab,
  ));
}

/// `--library` or `do2gether://library`: open on the media library rather than the join card.
bool wantsLibrary(List<String> args) => librarySource(args) != null;

/// The tab the library should open on: `--library=jellyfin`, `do2gether://library?source=jellyfin`,
/// or `DO2GETHER_LIBRARY_SOURCE=jellyfin`. Null when the library was not asked for.
String? librarySource(List<String> args) {
  final fromEnv = Platform.environment['DO2GETHER_LIBRARY_SOURCE']?.trim().toLowerCase();
  String? picked;
  for (final raw in args) {
    final v = raw.trim().toLowerCase();
    if (v == '--library' || v == 'do2gether://library' || v == 'watchtogether://library') {
      picked ??= '';
      continue;
    }
    if (v.startsWith('--library=')) {
      picked = v.substring('--library='.length);
      continue;
    }
    if (v.startsWith('do2gether://library') || v.startsWith('watchtogether://library')) {
      final source = Uri.tryParse(raw)?.queryParameters['source'];
      picked ??= source?.toLowerCase() ?? '';
    }
  }
  final value = (picked ?? '').isEmpty ? fromEnv : picked;
  return picked == null && (fromEnv == null || fromEnv.isEmpty) ? null : (value ?? '');
}

/// The OS launches the app with the invite URL as an argument when someone clicks
/// `do2gether://...` or an `https://<server>/join/<token>` link.
String? inviteFromArgs(List<String> args) {
  for (final arg in args) {
    if (arg.trim().isEmpty) continue;
    if (parseInviteLink(arg) != null) return arg.trim();
  }
  return null;
}

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({
    super.key,
    this.invite,
    this.invites,
    this.openLibrary = false,
    this.libraryTab,
  });

  /// Invite handed to us by the OS, already validated by [inviteFromArgs].
  final String? invite;

  /// Invites forwarded by later launches while this window is open.
  final Stream<String>? invites;

  /// Start on the media library instead of the join card.
  final bool openLibrary;

  /// The source tab to open it on (`jellyfin`, `local`, …); empty means the first available.
  final String? libraryTab;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'do2gether',
      theme: wtTheme(),
      home: HomeScreen(
        initialInvite: invite,
        forwardedInvites: invites,
        openLibrary: openLibrary,
        libraryTab: libraryTab,
      ),
    );
  }
}
