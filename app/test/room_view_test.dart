import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/format.dart';
import 'package:watch_together/room_controls.dart';
import 'package:watch_together/room_view.dart';
import 'package:watch_together/theme.dart';
import 'package:watch_together/widgets/button.dart';

import 'support.dart';

const List<RoomPerson> crowd = [
  RoomPerson(id: 'mika', name: 'Mika', host: true),
  RoomPerson(
    id: 'me',
    name: 'Sam',
    you: true,
    state: PersonState.drifting,
    driftMs: 2300,
  ),
  RoomPerson(id: 'jo', name: 'Jo', state: PersonState.noFile),
  RoomPerson(id: 'al', name: 'Al', state: PersonState.buffering),
  RoomPerson(id: 'ri', name: 'Ri', state: PersonState.reconnecting),
];

RoomViewData video({
  bool connected = true,
  bool playing = true,
  List<RoomPerson> people = crowd,
  PauseNotice? pause,
  String? waitingFor,
  bool fullscreen = false,
  double aspect = 16 / 9,
}) => RoomViewData(
  room: roomCode,
  title: "Mika's room",
  invite: 'https://example.com/join/abc.sig',
  connected: connected,
  people: people,
  nowPlaying: (title: 'movie-night_1080p.mkv', detail: '1:52:10'),
  upNext: const [(title: 'episode-02_1080p.mkv', detail: '24:10')],
  stage: StageMode.video,
  fileName: 'movie-night_1080p.mkv',
  positionMs: 724000,
  durationMs: 6730000,
  bufferedMs: 900000,
  playing: playing,
  pause: pause,
  waitingFor: waitingFor,
  fullscreen: fullscreen,
  aspect: aspect,
);

const RoomViewData empty = RoomViewData(
  room: roomCode,
  people: [
    RoomPerson(
      id: 'me',
      name: 'Sam',
      you: true,
      host: true,
      state: PersonState.noFile,
    ),
  ],
);

void main() {
  setUp(FakeClipboard().install);

  Future<void> pumpRoom(
    WidgetTester tester,
    RoomViewData data, {
    VoidCallback? onPlay,
    VoidCallback? onPause,
    ValueChanged<int>? onSeekBy,
    ValueChanged<int>? onSeekTo,
    VoidCallback? onFullscreen,
    VoidCallback? onToggleMute,
    VoidCallback? onOpenJellyfin,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wtTheme(),
        home: WtScaffold(
          child: RoomView(
            data: data,
            video: const ColoredBox(color: Colors.black),
            onBack: () {},
            onOpenFile: () {},
            onOpenJellyfin: onOpenJellyfin,
            onPlay: onPlay ?? () {},
            onPause: onPause ?? () {},
            onSeekBy: onSeekBy ?? (_) {},
            onSeekTo: onSeekTo ?? (_) {},
            onToggleMute: onToggleMute ?? () {},
            onFullscreen: onFullscreen ?? () {},
            onSettings: () {},
            onAddToQueue: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Dock tooltips carry their disabled reason (`Back 10 seconds · open a file first`), so match on
  /// the prefix rather than the whole string.
  WtTap tapFor(WidgetTester tester, String tooltip) => tester.widget<WtTap>(
    find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is Tooltip && (w.message ?? '').startsWith(tooltip),
          ),
          matching: find.byType(WtTap),
        )
        .first,
  );

  group('ready pill', () {
    test('label counts ready people, then says all in sync', () {
      expect(readyPillLabel(2, 3), '2 of 3 ready');
      expect(readyPillLabel(3, 3), 'All 3 in sync');
      expect(readyPillLabel(0, 1), '0 of 1 ready');
    });

    testWidgets('yellow N of M ready until everyone is synced', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpRoom(tester, video());
      expect(find.text('1 of 5 ready'), findsOneWidget);
    });

    testWidgets('turns into All M in sync', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpRoom(
        tester,
        video(
          people: const [
            RoomPerson(id: 'mika', name: 'Mika', host: true),
            RoomPerson(id: 'me', name: 'Sam', you: true),
            RoomPerson(id: 'jo', name: 'Jo'),
          ],
        ),
      );
      expect(find.text('All 3 in sync'), findsOneWidget);
      expect(find.textContaining('ready'), findsNothing);
    });

    testWidgets('default people are ready; one without a file is not', (
      tester,
    ) async {
      useWindow(tester, desktopSizes.first);
      const fresh = [
        RoomPerson(id: 'mika', name: 'Mika', host: true),
        RoomPerson(id: 'me', name: 'Sam', you: true),
        RoomPerson(id: 'jo', name: 'Jo'),
        RoomPerson(id: 'al', name: 'Al'),
      ];
      await pumpRoom(tester, video(people: fresh));
      expect(find.text('All 4 in sync'), findsOneWidget);

      await pumpRoom(
        tester,
        video(
          people: [
            ...fresh.take(3),
            const RoomPerson(id: 'al', name: 'Al', state: PersonState.noFile),
          ],
        ),
      );
      expect(find.text('3 of 4 ready'), findsOneWidget);
    });

    test('only drift beyond the seek threshold counts as not ready', () {
      RoomPerson drifting(double ms) => RoomPerson(
        id: 'x',
        name: 'X',
        state: PersonState.drifting,
        driftMs: ms,
      );
      expect(const RoomPerson(id: 'x', name: 'X').ready, isTrue);
      expect(drifting(-1200).ready, isTrue);
      expect(drifting(2300).ready, isFalse);
      for (final state in [
        PersonState.noFile,
        PersonState.buffering,
        PersonState.reconnecting,
      ]) {
        expect(RoomPerson(id: 'x', name: 'X', state: state).ready, isFalse);
      }
    });
  });

  group('stage', () {
    for (final size in [...desktopSizes, tiledSize]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      for (final (name, fileAspect, want) in [
        ('16:9 file', 16 / 9, 16 / 9),
        ('1.63:1 file', 1.63, 16 / 9),
        ('scope file', 2.39, 2.39),
      ]) {
        testWidgets('is ${want.toStringAsFixed(2)}:1 for a $name at $label', (
          tester,
        ) async {
          useWindow(tester, size);
          await pumpRoom(
            tester,
            RoomViewData(
              room: roomCode,
              people: crowd,
              stage: StageMode.video,
              aspect: fileAspect,
            ),
          );
          final stage = tester.getRect(find.byKey(roomStageKey));
          expect(stage.width / stage.height, closeTo(want, 0.01));
          // Centred in the space left of the rail (the rail is a sheet when tiled).
          final left = size.width - (size.width < 1024 ? 0 : 320);
          expect(stage.center.dx, closeTo(left / 2, 0.5));
        });
      }
    }

    testWidgets('empty stage is 16:9 too', (tester) async {
      useWindow(tester, desktopSizes.first);
      await pumpRoom(tester, empty);
      final stage = tester.getSize(find.byKey(roomStageKey));
      expect(stage.width / stage.height, closeTo(16 / 9, 0.01));
    });
  });

  testWidgets('tiled: the rail becomes a sheet behind the people button', (
    tester,
  ) async {
    useWindow(tester, tiledSize);
    await pumpRoom(tester, video());
    expect(find.text('IN THIS ROOM'), findsNothing);
    await tester.tap(find.byTooltip('People and queue'));
    await tester.pump();
    expect(find.text('IN THIS ROOM'), findsOneWidget);
    expect(find.text('Drifting +2s'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('IN THIS ROOM'), findsNothing);
  });

  testWidgets('rail shows every person state, HOST tag and queue', (
    tester,
  ) async {
    useWindow(tester, desktopSizes.first);
    await pumpRoom(tester, video());
    expect(find.text('Synced'), findsOneWidget);
    expect(find.text('Drifting +2s'), findsOneWidget);
    expect(find.text('No file'), findsOneWidget);
    expect(find.text('Buffering'), findsOneWidget);
    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('HOST'), findsOneWidget);
    expect(find.text(' (you)'), findsOneWidget);
    expect(find.text('Now playing · 1:52:10'), findsOneWidget);
    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.text('Nothing queued'), findsNothing);
    expect(find.text('12:04 / 1:52:10'), findsOneWidget);
  });

  testWidgets('empty room: open-file stage, dimmed dock, nothing queued', (
    tester,
  ) async {
    useWindow(tester, desktopSizes.first);
    await pumpRoom(tester, empty);
    expect(find.text('Open a file to watch together'), findsOneWidget);
    expect(find.text('Open file'), findsOneWidget);
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(tapFor(tester, 'Play (Space)').onTap, isNull);
    expect(tapFor(tester, 'Back 10 seconds').onTap, isNull);
    expect(tapFor(tester, 'Fullscreen (F)').onTap, isNull);
  });

  testWidgets('waiting stage says the room has another file', (tester) async {
    useWindow(tester, desktopSizes.first);
    await pumpRoom(
      tester,
      const RoomViewData(room: roomCode, stage: StageMode.waiting),
    );
    expect(find.text("Open the room's file to join"), findsOneWidget);
    expect(find.text('Open that file…'), findsOneWidget);
  });

  testWidgets('a paused room names who it waits for', (tester) async {
    useWindow(tester, desktopSizes.first);
    await pumpRoom(
      tester,
      video(
        playing: false,
        waitingFor: 'Mika',
        pause: const PauseNotice(serial: 1, positionMs: 724000, by: 'Mika'),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Waiting for Mika to press play'), findsOneWidget);
  });

  testWidgets('disconnected: banner, controls off, room still visible', (
    tester,
  ) async {
    useWindow(tester, desktopSizes.first);
    final handle = tester
        .ensureSemantics(); // bySemanticsLabel needs a semantics tree
    await pumpRoom(tester, video(connected: false));
    expect(find.textContaining('Reconnecting…'), findsOneWidget);
    // The tile merges its title and detail into one label; match the title inside it.
    expect(
      find.bySemanticsLabel(RegExp('movie-night_1080p\\.mkv')),
      findsWidgets,
    );
    expect(tapFor(tester, 'Pause (Space)').onTap, isNull);
    expect(tapFor(tester, 'Ahead 10 seconds').onTap, isNull);
    handle.dispose(); // must happen inside the test body, not in a tearDown
  });

  testWidgets('keys: Space, arrows, F, M', (tester) async {
    useWindow(tester, desktopSizes.first);
    final calls = <String>[];
    await pumpRoom(
      tester,
      video(),
      onPause: () => calls.add('pause'),
      onSeekBy: (d) => calls.add('seek $d'),
      onFullscreen: () => calls.add('full'),
      onToggleMute: () => calls.add('mute'),
    );
    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyM,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(calls, ['pause', 'seek -5000', 'seek 5000', 'full', 'mute']);
  });

  testWidgets('scrubber is a slider for assistive tech', (tester) async {
    useWindow(tester, desktopSizes.first);
    final handle = tester.ensureSemantics();
    await pumpRoom(tester, video());
    expect(
      tester.getSemantics(find.byType(WtScrubber)),
      containsSemantics(
        isSlider: true,
        label: 'Seek',
        value: '12 minutes 4 seconds',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('pause toast with Resume, then a Paused-by badge', (
    tester,
  ) async {
    useWindow(tester, desktopSizes.first);
    var resumed = false;
    await pumpRoom(tester, video());
    await pumpRoom(
      tester,
      video(
        playing: false,
        pause: const PauseNotice(serial: 1, positionMs: 724000, by: 'Mika'),
      ),
      onPlay: () => resumed = true,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.textContaining('paused for everyone · 12:04', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Resume'));
    expect(resumed, isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.textContaining('paused for everyone', findRichText: true),
      findsNothing,
    );
    // Once the toast is gone the stage carries it: who it waits on, and that play is open to all.
    expect(find.textContaining('Anyone can press play'), findsOneWidget);
  });

  testWidgets('the empty stage offers Jellyfin only when it can be opened', (
    tester,
  ) async {
    var opened = 0;
    await pumpRoom(tester, empty, onOpenJellyfin: () => opened++);
    await tester.tap(find.text('Or pick from Jellyfin'));
    await tester.pumpAndSettle();
    expect(opened, 1);

    await pumpRoom(tester, empty);
    expect(find.text('Or pick from Jellyfin'), findsNothing);
    expect(find.text('Open file'), findsOneWidget);
  });

  group('fullscreen', () {
    const screen = Size(1440, 900);
    const hintText = 'Esc to exit · F toggles';

    /// A real mouse over the picture. Hover is what arms the idle timer (the `_pointerSeen` seam);
    /// the timer runs on the test's fake clock, so `tester.pump(chromeHideAfter)` stands in for
    /// 2.5 s of stillness without sleeping.
    Future<TestGesture> point(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 400));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(704, 404));
      await tester.pump();
      return mouse;
    }

    /// The idle window on the fake clock, then the fade.
    Future<void> idle(WidgetTester tester) async {
      await tester.pump(chromeHideAfter);
      await tester.pump(const Duration(milliseconds: 250));
    }

    double opacityOf(WidgetTester tester, Finder finder) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(of: finder, matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;

    double dock(WidgetTester tester) =>
        opacityOf(tester, find.byKey(roomDockKey));

    final noCursor = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.none,
    );

    for (final (name, aspect, height) in [
      ('16:9', 16 / 9, 810.0),
      ('scope', scopeAspect, 1440 / scopeAspect),
    ]) {
      for (final connected in [true, false]) {
        testWidgets(
          'a $name picture is the biggest rect, centred on black'
          '${connected ? '' : ', banner or not'}',
          (tester) async {
            useWindow(tester, screen);
            await pumpRoom(
              tester,
              video(fullscreen: true, connected: connected, aspect: aspect),
            );
            final stage = tester.getRect(find.byKey(roomStageKey));
            expect(stage.width, 1440);
            expect(stage.height, closeTo(height, 0.5));
            expect(stage.center, offsetMoreOrLessEquals(const Offset(720, 450)));
            expect(
              find.byWidgetPredicate(
                (w) => w is ColoredBox && w.color == Colors.black,
              ),
              findsWidgets,
            );
            expect(find.text('IN THIS ROOM'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('chrome stays up until a pointer is seen', (tester) async {
      useWindow(tester, screen);
      await pumpRoom(tester, video(fullscreen: true));
      await idle(tester);
      await idle(tester);
      expect(dock(tester), 1);
      expect(noCursor, findsNothing);
    });

    for (final playing in [true, false]) {
      testWidgets(
        'chrome and cursor hide after the idle window while '
        '${playing ? 'playing' : 'paused'}; the corner pills stay; a move restores',
        (tester) async {
          useWindow(tester, screen);
          await pumpRoom(tester, video(fullscreen: true, playing: playing));
          final mouse = await point(tester);
          await tester.pump(chromeHideAfter - const Duration(milliseconds: 1));
          expect(dock(tester), 1);
          expect(noCursor, findsNothing);

          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump(const Duration(milliseconds: 250));
          expect(dock(tester), 0);
          expect(opacityOf(tester, find.text("Mika's room")), 0);
          expect(noCursor, findsOneWidget);
          expect(find.byTooltip('Ahead 10 seconds').hitTestable(), findsNothing);
          if (!playing) {
            expect(opacityOf(tester, find.text('Play for everyone')), 0);
            expect(find.text('Play for everyone').hitTestable(), findsNothing);
          }
          // The owner's rule: the way out and the controls toggle never fade.
          expect(find.text('Exit fullscreen').hitTestable(), findsOneWidget);
          expect(find.text('Show controls').hitTestable(), findsOneWidget);

          await mouse.moveBy(const Offset(12, 0));
          await tester.pump();
          expect(dock(tester), 1);
          expect(noCursor, findsNothing);
          expect(find.byTooltip('Ahead 10 seconds').hitTestable(), findsOne);
        },
      );
    }

    testWidgets('a key or a click brings the chrome back', (tester) async {
      useWindow(tester, screen);
      await pumpRoom(tester, video(fullscreen: true));
      final mouse = await point(tester);
      await idle(tester);
      expect(dock(tester), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(dock(tester), 1);
      expect(noCursor, findsNothing);

      await idle(tester);
      expect(dock(tester), 0);
      await mouse.down(const Offset(704, 404));
      await tester.pump();
      expect(dock(tester), 1);
      await mouse.up();
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('Show controls keeps the chrome up until it is turned off', (
      tester,
    ) async {
      useWindow(tester, screen);
      await pumpRoom(tester, video(fullscreen: true));
      await point(tester);
      await tester.tap(find.text('Show controls'));
      await tester.pump();
      await idle(tester);
      await idle(tester);
      expect(dock(tester), 1);
      expect(noCursor, findsNothing);

      await tester.tap(find.text('Show controls'));
      await tester.pump();
      expect(dock(tester), 1);
      await idle(tester);
      expect(dock(tester), 0);
    });

    testWidgets(
      'click the picture to play or pause, double-click to leave; the dock keeps its clicks',
      (tester) async {
        useWindow(tester, screen);
        final calls = <String>[];
        Future<void> pump(bool playing) => pumpRoom(
          tester,
          video(fullscreen: true, playing: playing),
          onPlay: () => calls.add('play'),
          onPause: () => calls.add('pause'),
          onSeekBy: (d) => calls.add('seek $d'),
          onFullscreen: () => calls.add('full'),
        );
        await pump(true);
        // Off centre, so the paused card never sits under it.
        final picture =
            tester.getRect(find.byKey(roomStageKey)).topLeft +
            const Offset(200, 200);
        await tester.tapAt(picture);
        await tester.pump(kDoubleTapTimeout);
        expect(calls, ['pause']);

        await tester.tapAt(picture);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(picture);
        await tester.pump(kDoubleTapTimeout);
        expect(calls, ['pause', 'full']);

        await tester.tap(find.text('+10s'));
        await tester.pump(kDoubleTapTimeout);
        await tester.tap(find.byTooltip('Pause (Space)'));
        await tester.pump(kDoubleTapTimeout);
        expect(calls, ['pause', 'full', 'seek 10000', 'pause']);

        await pump(false);
        await tester.tapAt(picture);
        await tester.pump(kDoubleTapTimeout);
        expect(calls.last, 'play');
        expect(calls, hasLength(5));
      },
    );

    testWidgets('Esc leaves, F toggles, and the hint fades without blocking a click', (
      tester,
    ) async {
      useWindow(tester, screen);
      final calls = <String>[];
      await pumpRoom(
        tester,
        video(fullscreen: true),
        onPause: () => calls.add('pause'),
        onFullscreen: () => calls.add('full'),
      );
      final hint = find.text(hintText);
      expect(opacityOf(tester, hint), 1);
      await tester.tapAt(tester.getCenter(hint));
      await tester.pump(kDoubleTapTimeout);
      expect(calls, ['pause']);

      await tester.pump(fullscreenHintFor);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacityOf(tester, hint), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect(calls, ['pause', 'full', 'full']);
    });

    testWidgets('leaving restores the window layout, dock and pointer', (
      tester,
    ) async {
      useWindow(tester, screen);
      await pumpRoom(tester, video());
      final window = tester.getRect(find.byKey(roomStageKey));
      Decoration? dockDecoration() => tester
          .widget<Container>(
            find
                .descendant(
                  of: find.byKey(roomDockKey),
                  matching: find.byType(Container),
                )
                .first,
          )
          .decoration;
      final windowDock = dockDecoration();

      await pumpRoom(tester, video(fullscreen: true));
      await point(tester);
      await tester.tap(find.text('Show controls'));
      await tester.tap(find.text('Show controls'));
      await idle(tester);
      expect(noCursor, findsOneWidget);

      await pumpRoom(tester, video());
      expect(noCursor, findsNothing);
      expect(tester.getRect(find.byKey(roomStageKey)), window);
      expect(dockDecoration(), windowDock);
      expect(tester.getBottomLeft(find.byKey(roomDockKey)).dy, screen.height);
      expect(find.text('IN THIS ROOM'), findsOneWidget);
      expect(find.text('Exit fullscreen'), findsNothing);
      expect(find.text(hintText), findsNothing);
      await idle(tester);
      await idle(tester);
      expect(noCursor, findsNothing);
      expect(find.byTooltip('Ahead 10 seconds').hitTestable(), findsOne);

      // Back in: the hint returns and Show controls starts off again.
      await pumpRoom(tester, video(fullscreen: true));
      expect(opacityOf(tester, find.text(hintText)), 1);
      await idle(tester);
      expect(dock(tester), 0);
    });
  });

  for (final size in [...desktopSizes, tiledSize]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';
    for (final (name, data) in [
      ('empty', empty),
      ('video', video()),
      ('disconnected', video(connected: false)),
      (
        'waiting',
        const RoomViewData(
          room: roomCode,
          stage: StageMode.waiting,
          mismatch: true,
        ),
      ),
    ]) {
      testWidgets('Room fits $label $name', (tester) async {
        useWindow(tester, size);
        await pumpRoom(tester, data);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Room fits $label with the pause toast', (tester) async {
      useWindow(tester, size);
      await pumpRoom(tester, video());
      await pumpRoom(
        tester,
        video(
          playing: false,
          pause: const PauseNotice(serial: 1, positionMs: 724000, by: 'Mika'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  }
}
