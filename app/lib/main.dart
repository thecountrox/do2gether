import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const WatchTogetherApp());
}

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'watch-together',
      theme: wtTheme(),
      home: const HomeScreen(),
    );
  }
}
