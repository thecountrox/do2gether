import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/home_screen.dart';
import 'package:watch_together/theme.dart';

String token(String room) =>
    '${base64Url.encode(utf8.encode(jsonEncode({'room': room, 'exp': 123456789}))).replaceAll('=', '')}.signature';

void main() {
  Future<void> pumpHome(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(theme: wtTheme(), home: const HomeScreen()),
  );

  testWidgets('invalid invite disables join', (tester) async {
    await pumpHome(tester);
    await tester.enterText(find.byType(TextField), 'garbage');
    await tester.pump();
    expect(
      find.text('Enter a valid invite link or room code and token'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: find.text('Join a room'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap,
      isNull,
    );
  });

  for (final invite in [
    'watchtogether://join?room=room42&token=example',
    'https://example.com/join/${token('room42')}',
  ]) {
    testWidgets('valid invite enables join and shows room: $invite', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.enterText(find.byType(TextField), invite);
      await tester.pump();
      expect(find.text('● room42'), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(
              find
                  .ancestor(
                    of: find.text('Join a room'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .onTap,
        isNotNull,
      );
    });
  }

  test('server URL accepts http and https only', () {
    expect(validateServerUrl(defaultServerUrl), isNull);
    expect(validateServerUrl('http://127.0.0.1:8787'), isNull);
    expect(validateServerUrl('ws://127.0.0.1:8787'), isNotNull);
  });

  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    testWidgets('Home fits ${size.width.toInt()}×${size.height.toInt()}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await pumpHome(tester);
      expect(find.text('watch together'), findsOneWidget);
      expect(find.text('Join a room'), findsOneWidget);
      expect(find.text('Start a room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
