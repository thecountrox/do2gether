import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the app font so layout tests measure real glyph widths instead of
/// the square test font, which is roughly twice as wide.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final loader = FontLoader('MPlusRounded');
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold', 'Black']) {
    final bytes = File(
      'assets/fonts/mplus/MPLUSRounded1c-$weight.ttf',
    ).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
  await testMain();
}
