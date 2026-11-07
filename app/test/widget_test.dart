import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/join_screen.dart';
import 'package:watch_together/room_screen.dart';

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  Future<void> pumpJoin(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: JoinScreen()));

  testWidgets('JoinScreen rejects an empty room', (tester) async {
    await pumpJoin(tester);
    await tester.enterText(_field('Token'), 'some-token');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('Room id is required'), findsOneWidget);
    expect(find.text('Token is required'), findsNothing);
    expect(find.byType(RoomScreen), findsNothing);
  });

  testWidgets('JoinScreen rejects a bad URL', (tester) async {
    await pumpJoin(tester);
    expect(find.text(defaultServerUrl), findsOneWidget);
    await tester.enterText(_field('Room id'), 'k3x9a0qz');
    await tester.enterText(_field('Token'), 'some-token');

    for (final bad in ['ftp://example.com', 'not a url', 'https://', '']) {
      await tester.enterText(_field('Server URL'), bad);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an http:// or https:// server URL'), findsOneWidget, reason: bad);
      expect(find.byType(RoomScreen), findsNothing, reason: bad);
    }
  });

  test('validateServerUrl accepts http and https only', () {
    expect(validateServerUrl(defaultServerUrl), isNull);
    expect(validateServerUrl('http://127.0.0.1:8787'), isNull);
    expect(validateServerUrl('ws://127.0.0.1:8787'), isNotNull);
    expect(validateServerUrl('127.0.0.1:8787'), isNotNull);
  });
}
