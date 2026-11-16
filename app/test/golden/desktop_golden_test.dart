// Renders the real widget tree at the shipping window size and writes PNGs.
// Run: flutter test test/golden/desktop_golden_test.dart --update-goldens
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/home_screen.dart';
import 'package:watch_together/room_view.dart';
import 'package:watch_together/theme.dart';

import '../support.dart';

const RoomViewData _room = RoomViewData(
  room: 'k3f9x2qa',
  title: "Mika's room",
  invite: 'https://watch.example/join/tok.sig',
  connected: true,
  people: [
    RoomPerson(id: 'mika', name: 'Mika', host: true),
    RoomPerson(id: 'me', name: 'Sam', you: true),
    RoomPerson(id: 'jo', name: 'Jo', state: PersonState.noFile),
    RoomPerson(id: 'al', name: 'Al', state: PersonState.buffering),
  ],
  nowPlaying: (title: 'sample-room', detail: '0:20'),
  upNext: [
    (title: 'episode-02_1080p.mkv', detail: '24:10'),
    (title: 'bonus_credits.mkv', detail: '4:11'),
  ],
  stage: StageMode.video,
  fileName: 'sample-room',
  source: MediaSource.jellyfin,
  positionMs: 724000,
  durationMs: 6730000,
  bufferedMs: 1900000,
  playing: true,
  rate: 1.25,
  sync: SyncState.adjusting,
  driftMs: 180,
);

const RoomViewData _fullscreenRoom = RoomViewData(
  room: 'k3f9x2qa',
  title: "Mika's room",
  invite: 'https://watch.example/join/tok.sig',
  connected: true,
  people: [
    RoomPerson(id: 'mika', name: 'Mika', host: true),
    RoomPerson(id: 'me', name: 'Sam', you: true),
    RoomPerson(id: 'jo', name: 'Jo', state: PersonState.noFile),
    RoomPerson(id: 'al', name: 'Al', state: PersonState.buffering),
  ],
  nowPlaying: (title: 'sample-room', detail: '0:20'),
  stage: StageMode.video,
  fileName: 'sample-room',
  source: MediaSource.jellyfin,
  positionMs: 724000,
  durationMs: 6730000,
  bufferedMs: 1900000,
  playing: true,
  rate: 1.25,
  sync: SyncState.adjusting,
  driftMs: 180,
  fullscreen: true,
);

void main() {
  // Without the icon font every Icon renders as an empty square.
  setUpAll(() async {
    final loader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await loader.load();
  });

  for (final idle in [false, true]) {
    final name = idle ? 'fullscreen_1440_idle' : 'fullscreen_1440';
    testWidgets('fullscreen at 1440x900${idle ? ', chrome hidden' : ''}', (
      tester,
    ) async {
      useWindow(tester, const Size(1440, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: wtTheme(),
          debugShowCheckedModeBanner: false,
          home: WtScaffold(
            child: RoomView(
              data: _fullscreenRoom,
              video: const ColoredBox(color: Color(0xFF120A19)),
              onBack: () {},
              onOpenFile: () {},
              onPlay: () {},
              onPause: () {},
              onSeekBy: (_) {},
              onSeekTo: (_) {},
              onToggleMute: () {},
              onFullscreen: () {},
              onSettings: () {},
              onAddToQueue: () {},
            ),
          ),
        ),
      );
      if (idle) {
        // A mouse arms the idle timer; the fake clock runs it out.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(700, 400));
        await mouse.moveTo(const Offset(704, 404));
        await tester.pump();
        await tester.pump(chromeHideAfter);
      }
      // Let the entry hint fade so both shots show the steady state.
      await tester.pump(fullscreenHintFor);
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$name.png'),
      );
    });
  }

  for (final (size, name) in [
    (const Size(1440, 900), '1440'),
    (tiledSize, '856'),
  ]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('home at $label', (tester) async {
      useWindow(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: wtTheme(),
          debugShowCheckedModeBanner: false,
          home: HomeScreen(
            api: FakeRoomApi(),
            pickCopy: () async => null,
            jellyfin: FakeJellyfinApi(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('home_$name.png'),
      );
    });

    testWidgets('room at $label', (tester) async {
      useWindow(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: wtTheme(),
          debugShowCheckedModeBanner: false,
          home: WtScaffold(
            child: RoomView(
              data: _room,
              video: const ColoredBox(color: Color(0xFF120A19)),
              onBack: () {},
              onOpenFile: () {},
              onPlay: () {},
              onPause: () {},
              onSeekBy: (_) {},
              onSeekTo: (_) {},
              onToggleMute: () {},
              onFullscreen: () {},
              onSettings: () {},
              onAddToQueue: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('room_$name.png'),
      );
    });
  }
}
