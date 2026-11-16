import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/home_screen.dart';
import 'package:watch_together/local_copy.dart';
import 'package:watch_together/media_library.dart';
import 'package:watch_together/room_api.dart';
import 'package:watch_together/room_ready.dart';
import 'package:watch_together/theme.dart';
import 'package:watch_together/widgets/button.dart';
import 'package:watch_together/widgets/chrome.dart';

import 'support.dart';

const RoomInfo liveRoom = RoomInfo(
  roomId: roomCode,
  hostName: 'Mika',
  memberCount: 2,
  memberNames: ['Mika', 'Jo'],
  itemRef: hostRef,
  positionMs: 724000,
  paused: false,
);

void main() {
  final clipboard = FakeClipboard();
  setUp(clipboard.install);

  Future<void> pumpHome(
    WidgetTester tester, {
    FakeRoomApi? api,
    LocalCopy? pick = hostCopy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wtTheme(),
        home: HomeScreen(
          api: api ?? FakeRoomApi(),
          pickCopy: () async => pick,
          jellyfin: FakeJellyfinApi(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> paste(WidgetTester tester, String invite) async {
    await tester.enterText(find.byType(TextField), invite);
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// `Pick media`, then the empty `This computer` tab's `Choose file…`: the OS dialog's file plays
  /// and the library closes on it.
  Future<void> pickFile(WidgetTester tester) async {
    await tester.tap(find.text('Pick media'));
    await settle(tester);
    expect(find.byType(MediaLibrary), findsOneWidget);
    await tester.tap(find.widgetWithText(WtButton, 'Choose file…'));
    await settle(tester);
    expect(find.byType(MediaLibrary), findsNothing);
  }

  WtButton? joinButton(WidgetTester tester, String label) {
    final found = find.widgetWithText(WtButton, label);
    return found.evaluate().isEmpty ? null : tester.widget<WtButton>(found);
  }

  group('Home', () {
    testWidgets('shows the brand column, steps and server status', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester);
      expect(find.text('One screen.'), findsOneWidget);
      expect(find.text('Same moment.'), findsOneWidget);
      expect(find.text('Paste the invite'), findsOneWidget);
      expect(find.text('Open your copy'), findsOneWidget);
      expect(find.text('Press play'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.textContaining('Connected to '), findsOneWidget);
      expect(find.textContaining('· 42 ms'), findsOneWidget);
      expect(find.text('Change server'), findsOneWidget);
      expect(find.text('Join a room'), findsOneWidget);
      expect(find.text('Start a room'), findsOneWidget);
      expect(find.text('Paste an invite to join'), findsOneWidget);
      expect(find.text('How it works'), findsNothing);
    });

    testWidgets('tiled: brand stacks above a full-width card, steps fold', (
      tester,
    ) async {
      useWindow(tester, tiledSize);
      await pumpHome(tester);
      expect(
        tester.getBottomLeft(find.text('Same moment.')).dy,
        lessThan(tester.getTopLeft(find.byKey(homeCardKey)).dy),
      );
      expect(
        tester.getSize(find.byKey(homeCardKey)).width,
        tiledSize.width - 2 * WtSpace.window,
      );
      expect(find.text('Change server'), findsOneWidget);
      expect(find.text('Paste the invite'), findsNothing);

      await tester.tap(find.text('How it works'));
      await tester.pumpAndSettle();
      expect(find.text('Paste the invite'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('How it works'));
      await tester.pumpAndSettle();
      expect(find.text('Paste the invite'), findsNothing);
    });

    testWidgets('malformed link gets a calm inline error', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester);
      await paste(tester, 'https://example.com/join/garbage');
      expect(find.textContaining('That link looks cut off'), findsOneWidget);
      expect(find.text('Paste an invite to join'), findsOneWidget);
    });

    testWidgets('found room asks for your copy, then enables join', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      final api = FakeRoomApi(info: liveRoom);
      await pumpHome(tester, api: api);
      await paste(
        tester,
        'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
      );
      expect(api.lookups, 1);
      expect(find.text('Live now'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is WtKeyCaps && w.code == roomCode),
        findsOneWidget,
      );
      expect(find.text('Open your copy to join'), findsOneWidget);
      expect(joinButton(tester, "Join Mika's room"), isNull);
      expect(find.text('Choose file…'), findsNothing);
      expect(find.widgetWithText(WtTextButton, 'Jellyfin'), findsNothing);

      await pickFile(tester);
      expect(find.text('Open your copy to join'), findsNothing);
      expect(joinButton(tester, "Join Mika's room")?.onPressed, isNotNull);
      expect(
        find.textContaining('Your copy matches', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('DONE'), findsNWidgets(2));
    });

    testWidgets('paste button reads the clipboard', (tester) async {
      useWindow(tester, desktopSizes.first);
      clipboard.text =
          ' https://example.com/join/${token(roomCode, exp: inTenMinutes())}\n';
      await pumpHome(tester, api: FakeRoomApi(info: liveRoom));
      await tester.tap(find.byTooltip('Paste'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Live now'), findsOneWidget);
    });

    testWidgets('expired link to a live room offers to ask for a new one', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester, api: FakeRoomApi(info: liveRoom));
      await paste(tester, 'https://example.com/join/${token(roomCode)}');
      expect(
        find.text('This link expired, but the room is still running'),
        findsOneWidget,
      );
      expect(find.text('Live now · 2 inside'), findsOneWidget);
      await tester.tap(find.text('Ask for a new link'));
      await tester.pump();
      expect(clipboard.text, contains(roomCode));
    });

    testWidgets('ended room says so', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester, api: FakeRoomApi());
      await paste(
        tester,
        'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
      );
      expect(find.text('This room has ended'), findsOneWidget);
      expect(find.text('Start a room'), findsNWidgets(2));
    });

    testWidgets('lookup failure fails open', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester, api: FakeRoomApi(fail: true));
      await paste(
        tester,
        'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
      );
      expect(find.text("Couldn't check"), findsOneWidget);
      await pickFile(tester);
      expect(joinButton(tester, 'Join room')?.onPressed, isNotNull);
    });

    testWidgets('Library in the brand column opens the library on its own', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester);
      await tester.tap(find.text('Library'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsOneWidget);
      expect(find.text('Nothing in this library yet'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(MediaLibrary), findsNothing);
      expect(find.text('Paste an invite to join'), findsOneWidget);
    });

    testWidgets('a file picked once is in This computer next time', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      await pumpHome(tester, api: FakeRoomApi(info: liveRoom));
      await paste(
        tester,
        'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
      );
      await pickFile(tester);
      await tester.tap(find.text('Library'));
      await settle(tester);
      expect(find.text('movie-night_1080p.mkv'), findsOneWidget);
      expect(find.text('Nothing in this library yet'), findsNothing);
    });

    for (final size in [...desktopSizes, tiledSize]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('fits $label empty', (tester) async {
        useWindow(tester, size);
        await pumpHome(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('fits $label with a found room and a copy', (tester) async {
        useWindow(tester, size);
        await pumpHome(tester, api: FakeRoomApi(info: liveRoom));
        await paste(
          tester,
          'https://example.com/join/${token(roomCode, exp: inTenMinutes())}',
        );
        await pickFile(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('fits $label with an expired link', (tester) async {
        useWindow(tester, size);
        await pumpHome(tester, api: FakeRoomApi(info: liveRoom));
        await paste(tester, 'https://example.com/join/${token(roomCode)}');
        expect(tester.takeException(), isNull);
      });
    }
  });

  test('server URL accepts http and https only', () {
    expect(validateServerUrl(defaultServerUrl), isNull);
    expect(validateServerUrl('http://127.0.0.1:8787'), isNull);
    expect(validateServerUrl('ws://127.0.0.1:8787'), isNotNull);
  });

  group('Room ready dialog', () {
    Future<Future<bool?>> open(
      WidgetTester tester, {
      LocalCopy? copy,
      FakeRoomApi? api,
    }) async {
      late Future<bool?> result;
      final room = await FakeRoomApi().create(Uri.parse(defaultServerUrl));
      await tester.pumpWidget(
        MaterialApp(
          theme: wtTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => result = showRoomReady(
                    context,
                    server: Uri.parse(defaultServerUrl),
                    created: room,
                    name: 'Sam',
                    copy: copy,
                    api: api ?? FakeRoomApi(),
                    pickCopy: () async => hostCopy,
                    onCopy: (_) {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return result;
    }

    testWidgets('shows code, link, readiness and footer', (tester) async {
      useWindow(tester, desktopSizes.first);
      await open(tester);
      expect(find.text('read it out — no 0/O or 1/I'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('No file yet'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget);
      expect(find.text('Nudge'), findsOneWidget);
      expect(find.text('Choose your copy'), findsOneWidget);
      expect(find.text('Enter room'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.textContaining('Code expires in 9:5'), findsOneWidget);
      expect(find.textContaining('Nothing is uploaded'), findsNothing);
    });

    testWidgets('copy flips to Copied for 1.5 s', (tester) async {
      useWindow(tester, desktopSizes.first);
      await open(tester);
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      expect(clipboard.text, contains('/join/'));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('your copy turns you Ready; joiners appear', (tester) async {
      useWindow(tester, desktopSizes.first);
      final api = FakeRoomApi(
        info: const RoomInfo(
          roomId: roomCode,
          hostName: 'Sam',
          memberCount: 2,
          memberNames: ['Sam', 'Jo'],
        ),
      );
      await open(tester, api: api);
      await tester.tap(find.text('Choose your copy'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining('Plays from your disk'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Jo'), findsOneWidget);
      expect(find.text('Joined'), findsOneWidget);
    });

    testWidgets('Enter room resolves true', (tester) async {
      useWindow(tester, desktopSizes.first);
      final result = await open(tester, copy: hostCopy);
      await tester.tap(find.text('Enter room'));
      await tester.pump();
      expect(await result, isTrue);
    });

    for (final size in desktopSizes) {
      testWidgets('fits ${size.width.toInt()}x${size.height.toInt()}', (
        tester,
      ) async {
        useWindow(tester, size);
        await open(tester, copy: hostCopy);
        expect(find.text('Enter room'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
