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
  final instance = SingleInstance();

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

  runApp(WatchTogetherApp(invite: invite, invites: instance.invites));
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
  const WatchTogetherApp({super.key, this.invite, this.invites});

  /// Invite handed to us by the OS, already validated by [inviteFromArgs].
  final String? invite;

  /// Invites forwarded by later launches while this window is open.
  final Stream<String>? invites;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'do2gether',
      theme: wtTheme(),
      home: HomeScreen(initialInvite: invite, forwardedInvites: invites),
    );
  }
}
