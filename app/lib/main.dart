import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_screen.dart';
import 'links.dart';
import 'scheme_install.dart';
import 'theme.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Tarball and zip builds have no installer, so the app claims the invite scheme itself.
  if (!kIsWeb) {
    unawaited(
      ensureInviteScheme(
        executable: Platform.resolvedExecutable,
        home: Platform.environment['HOME'] ?? '',
      ),
    );
  }
  runApp(WatchTogetherApp(invite: inviteFromArgs(args)));
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
  const WatchTogetherApp({super.key, this.invite});

  /// Invite handed to us by the OS, already validated by [inviteFromArgs].
  final String? invite;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'do2gether',
      theme: wtTheme(),
      home: HomeScreen(initialInvite: invite),
    );
  }
}
