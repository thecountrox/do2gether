import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/home_screen.dart';
import 'package:watch_together/jellyfin.dart';
import 'package:watch_together/jellyfin_picker.dart';
import 'package:watch_together/room_api.dart';
import 'package:watch_together/theme.dart';
import 'package:watch_together/widgets/button.dart';

import 'support.dart';

final Uri jellyServer = Uri.parse('https://jelly.example');

final RoomInfo jellyRoom = RoomInfo(
  roomId: roomCode,
  hostName: 'Mika',
  memberCount: 2,
  memberNames: const ['Mika', 'Jo'],
  itemRef: jellyfinRef(jellyServer, jellyItemId),
  positionMs: 4000,
  paused: false,
);

void main() {
  Future<void> pumpHome(WidgetTester tester, FakeJellyfinApi jellyfin) async {
    useWindow(tester, desktopSizes.first);
    await tester.pumpWidget(
      MaterialApp(
        theme: wtTheme(),
        home: HomeScreen(
          api: FakeRoomApi(info: jellyRoom),
          pickCopy: () async => null,
          jellyfin: jellyfin,
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(WtTextButton, 'Jellyfin'));
    await settle(tester);
    expect(find.byType(JellyfinDialog), findsOneWidget);
  }

  Finder dialogField(int i) => find
      .descendant(
        of: find.byType(JellyfinDialog),
        matching: find.byType(TextField),
      )
      .at(i);

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(dialogField(0), 'https://jelly.example');
    await tester.enterText(dialogField(1), 'root');
    await tester.tap(find.widgetWithText(WtButton, 'Connect'));
    await settle(tester);
  }

  WtButton joinButton(WidgetTester tester) => tester.widget<WtButton>(
    find.widgetWithText(WtButton, "Join Mika's room"),
  );

  testWidgets(
    'sign in, list movies, pick one: the copy is set and Join enabled',
    (tester) async {
      final jellyfin = FakeJellyfinApi();
      await pumpHome(tester, jellyfin);
      expect(find.text('Open your copy to join'), findsOneWidget);

      await openDialog(tester);
      expect(find.text('SERVER'), findsOneWidget);
      expect(find.text('PASSWORD'), findsOneWidget);

      await signIn(tester);
      expect(jellyfin.connects, hasLength(1));
      expect(jellyfin.connects.single.server, jellyServer);
      expect(jellyfin.connects.single.user, 'root');
      expect(jellyfin.connects.single.pass, '');
      expect(find.text('Signed in as root on jelly.example'), findsOneWidget);
      expect(find.text('PICK A MOVIE'), findsOneWidget);
      expect(find.text('Big Buck Bunny'), findsOneWidget);
      expect(find.text('sample-room'), findsOneWidget);
      expect(find.text('0:20'), findsOneWidget);

      await tester.tap(find.text('sample-room'));
      await settle(tester);
      expect(find.byType(JellyfinDialog), findsNothing);
      expect(find.text('Open your copy to join'), findsNothing);
      expect(
        find.textContaining(
          'Your copy matches · Jellyfin · 0:20',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(joinButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a saved sign-in opens straight on the movie list', (
    tester,
  ) async {
    final jellyfin = FakeJellyfinApi(
      saved: FakeJellyfinSession(server: jellyServer, user: 'root'),
    );
    await pumpHome(tester, jellyfin);
    await openDialog(tester);
    expect(find.text('SERVER'), findsNothing);
    expect(find.text('PICK A MOVIE'), findsOneWidget);
    expect(jellyfin.connects, isEmpty);

    // Change goes back to the form with the saved server pre-filled.
    await tester.tap(find.widgetWithText(WtTextButton, 'Change'));
    await settle(tester);
    expect(find.text('https://jelly.example'), findsOneWidget);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('a failed sign-in shows what the server said', (tester) async {
    final jellyfin = FakeJellyfinApi(
      error: const JellyfinException('Error processing request.', status: 401),
    );
    await pumpHome(tester, jellyfin);
    await openDialog(tester);
    await signIn(tester);
    expect(find.text('Error processing request. (HTTP 401)'), findsOneWidget);
    expect(find.text('PICK A MOVIE'), findsNothing);
    expect(find.widgetWithText(WtButton, 'Connect'), findsOneWidget);
  });

  testWidgets('a revoked saved token falls back to the form', (tester) async {
    final jellyfin = FakeJellyfinApi(
      saved: FakeJellyfinSession(
        server: jellyServer,
        user: 'root',
        fail: const JellyfinException('Access token is invalid', status: 401),
      ),
    );
    await pumpHome(tester, jellyfin);
    await openDialog(tester);
    expect(find.text('Access token is invalid (HTTP 401)'), findsOneWidget);
    expect(find.text('https://jelly.example'), findsOneWidget);
  });

  testWidgets('a bad server URL is caught before any request', (tester) async {
    final jellyfin = FakeJellyfinApi();
    await pumpHome(tester, jellyfin);
    await openDialog(tester);
    await tester.enterText(dialogField(0), 'jelly.example');
    await tester.enterText(dialogField(1), 'root');
    await tester.tap(find.widgetWithText(WtButton, 'Connect'));
    await settle(tester);
    expect(
      find.text('Enter an http:// or https:// server URL'),
      findsOneWidget,
    );
    expect(jellyfin.connects, isEmpty);
  });
}
