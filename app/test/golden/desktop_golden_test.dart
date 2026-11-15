// Renders the real widget tree at the shipping window size and writes PNGs.
// Run: flutter test test/golden/desktop_golden_test.dart --update-goldens
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
  nowPlaying: (title: 'movie-night_1080p.mkv', detail: '1:52:10'),
  upNext: [
    (title: 'episode-02_1080p.mkv', detail: '24:10'),
    (title: 'bonus_credits.mkv', detail: '4:11'),
  ],
  stage: StageMode.video,
  fileName: 'movie-night_1080p.mkv',
  positionMs: 724000,
  durationMs: 6730000,
  bufferedMs: 900000,
  playing: true,
);

void main() {
  // Without the icon font every Icon renders as an empty square.
  setUpAll(() async {
    final loader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await loader.load();
  });

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
