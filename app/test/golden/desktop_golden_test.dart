// Renders the real widget tree at the shipping window size and writes PNGs.
// Run: flutter test test/golden/desktop_golden_test.dart --update-goldens
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/home_screen.dart';
import 'package:watch_together/media.dart';
import 'package:watch_together/media_library.dart';
import 'package:watch_together/room_view.dart';
import 'package:watch_together/theme.dart';

import '../support.dart';

const String _jelly = 'https://jelly.example';

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
  nowPlaying: (
    title: 'sample-room',
    detail: '0:20',
    source: MediaSourceKind.jellyfin,
  ),
  upNext: [
    (
      title: 'episode-02_1080p.mkv',
      detail: '24:10',
      source: MediaSourceKind.jellyfin,
    ),
    (title: 'bonus_credits.mkv', detail: '4:11', source: MediaSourceKind.local),
  ],
  stage: StageMode.video,
  fileName: 'sample-room',
  source: MediaSourceKind.jellyfin,
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
  nowPlaying: (
    title: 'sample-room',
    detail: '0:20',
    source: MediaSourceKind.jellyfin,
  ),
  stage: StageMode.video,
  fileName: 'sample-room',
  source: MediaSourceKind.jellyfin,
  positionMs: 724000,
  durationMs: 6730000,
  bufferedMs: 1900000,
  playing: true,
  rate: 1.25,
  sync: SyncState.adjusting,
  driftMs: 180,
  fullscreen: true,
);

/// Candy gradients standing in for Jellyfin posters, so the goldens show art with no network.
Future<List<MemoryImage>> _renderPosters() async {
  const pairs = [
    (Color(0xFFFF5FA2), Color(0xFF4A2370)),
    (Color(0xFF3FE0D0), Color(0xFF243B8F)),
    (Color(0xFFFFD84D), Color(0xFFE0457B)),
    (Color(0xFF9B6BFF), Color(0xFF1E1035)),
    (Color(0xFF7BE07B), Color(0xFF1F5F6B)),
    (Color(0xFFFF9A5C), Color(0xFF6B1F45)),
  ];
  const size = Size(200, 300);
  return [
    for (final (i, (top, bottom)) in pairs.indexed)
      MemoryImage(await _poster(size, top, bottom, i)),
  ];
}

Future<Uint8List> _poster(Size size, Color top, Color bottom, int i) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          top,
          bottom,
        ]),
    )
    ..drawCircle(
      Offset(size.width * (0.3 + 0.08 * i), size.height * 0.38),
      size.width * 0.28,
      Paint()..color = const Color(0x40FFFFFF),
    )
    ..drawRect(
      Rect.fromLTWH(24, size.height - 64, size.width - 48, 10),
      Paint()..color = const Color(0x66FFFFFF),
    );
  final image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

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

    for (final mode in LibraryMode.values) {
      final queue = mode == LibraryMode.queue;
      testWidgets('library${queue ? ' in queue mode' : ''} at $label', (
        tester,
      ) async {
        useWindow(tester, size);
        final posters = (await tester.runAsync(_renderPosters))!;
        final local = LocalMediaSource(pickFile: () async => null)
          ..remember(hostCopy);
        final jellyfin = JellyfinMediaSource(
          api: FakeJellyfinApi(saved: ShelfSession(server: Uri.parse(_jelly))),
          signIn: (_) async => null,
        );
        await jellyfin.restore();
        await tester.pumpWidget(
          MaterialApp(
            theme: wtTheme(),
            debugShowCheckedModeBanner: false,
            home: MediaLibrary(
              sources: mediaSources(local: local, jellyfin: jellyfin),
              mode: mode,
              initial: MediaSourceKind.jellyfin,
              onQueue: queue ? (_) {} : null,
              poster: (url) =>
                  posters[shelfMovies.indexWhere((m) => url.contains(m.id)) %
                      posters.length],
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final context = tester.element(find.byType(MediaLibrary));
          for (final poster in posters) {
            await precacheImage(poster, context);
          }
        });
        await tester.pump();
        if (queue) {
          for (final title in ['Big Buck Bunny', 'Elephants Dream']) {
            await tester.tap(find.text(title));
            await tester.pump();
            await tester.tap(find.text('Queue this'));
            await tester.pump();
          }
        }
        await tester.tap(find.text('Cosmos Laundromat'));
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('library_${queue ? 'queue_' : ''}$name.png'),
        );
      });
    }

    if (name == '1440') {
      testWidgets('library with no search matches at $label', (tester) async {
        useWindow(tester, size);
        final jellyfin = JellyfinMediaSource(
          api: FakeJellyfinApi(saved: ShelfSession(server: Uri.parse(_jelly))),
          signIn: (_) async => null,
        );
        await jellyfin.restore();
        await tester.pumpWidget(
          MaterialApp(
            theme: wtTheme(),
            debugShowCheckedModeBanner: false,
            home: MediaLibrary(
              sources: mediaSources(
                local: LocalMediaSource(pickFile: () async => null),
                jellyfin: jellyfin,
              ),
              initial: MediaSourceKind.jellyfin,
            ),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'zzz');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('library_no_match_$name.png'),
        );
      });
    }

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
