import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/format.dart';
import 'package:watch_together/jellyfin.dart';
import 'package:watch_together/local_copy.dart';
import 'package:watch_together/media.dart';
import 'package:watch_together/media_library.dart';
import 'package:watch_together/theme.dart';
import 'package:watch_together/widgets/button.dart';

import 'support.dart';

final Uri jellyServer = Uri.parse('https://jelly.example');

/// Never decodes in fake time, so every card shows its fallback glyph.
ImageProvider blankPoster(String url) => MemoryImage(Uint8List(0));

/// A source with a fixed shelf; [ready] flips on `ensureReady`.
class FakeSource extends MediaSource {
  FakeSource(
    this.label, {
    this.items = const [],
    this.ready = true,
    this.kind = MediaSourceKind.local,
  });

  @override
  final MediaSourceKind kind;
  @override
  final String label;
  @override
  bool ready;
  final List<MediaItem> items;

  @override
  Future<List<MediaItem>> browse({String query = ''}) async => [
    for (final item in items)
      if (mediaMatches(item, query)) item,
  ];

  @override
  Future<void> ensureReady() async => ready = true;

  @override
  Future<LocalCopy?> open(MediaItem item) async =>
      LocalCopy(path: '/videos/${item.title}.mkv', bytes: 1, itemRef: item.ref);
}

MediaItem film(String title, {MediaKind kind = MediaKind.video}) => MediaItem(
  ref: 'file:sha256p:1:${title.hashCode}',
  title: title,
  subtitle: '1.4 GB',
  kind: kind,
  source: MediaSourceKind.local,
  duration: const Duration(minutes: 24, seconds: 10),
);

final List<MediaItem> shelf = [
  film('Big Buck Bunny'),
  film('Sintel'),
  film('Tears of Steel'),
  film('Night radio', kind: MediaKind.audio),
  film('Harbour cam', kind: MediaKind.live),
];

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Pushes the library over a blank screen; the future is what it closes with.
  Future<Future<LocalCopy?>> openLibrary(
    WidgetTester tester, {
    required List<MediaSource> sources,
    LibraryMode mode = LibraryMode.play,
    MediaSourceKind? initial,
    ValueChanged<MediaItem>? onQueue,
  }) async {
    useWindow(tester, desktopSizes.first);
    late Future<LocalCopy?> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: wtTheme(),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => result = showMediaLibrary(
                context,
                sources: sources,
                mode: mode,
                initial: initial,
                onQueue: onQueue,
                poster: blankPoster,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.byType(MediaLibrary), findsOneWidget);
    return result;
  }

  group('model', () {
    test('a local copy round-trips through its item', () async {
      final source = LocalMediaSource(pickFile: () async => hostCopy);
      final item = LocalMediaSource.itemFor(hostCopy);
      expect(item.ref, hostRef);
      expect(item.title, 'movie-night_1080p.mkv');
      expect(item.subtitle, fmtBytes(hostCopy.bytes));
      expect(item.kind, MediaKind.video);
      expect(item.source, MediaSourceKind.local);
      expect(item.duration, hostCopy.duration);
      expect(item.posterUrl, isNull);
      expect(sourceKindOf(item.ref), MediaSourceKind.local);

      // Nothing to browse until a file is opened; then it opens as the same copy.
      expect(await source.browse(), isEmpty);
      expect(await source.open(item), isNull);
      await source.pick();
      expect([for (final i in await source.browse()) i.ref], [hostRef]);
      expect((await source.open(item))?.itemRef, hostRef);
    });

    test(
      'remote copies stay out of This computer; audio is badged as audio',
      () async {
        final source = LocalMediaSource(pickFile: () async => null)
          ..remember(
            const LocalCopy.remote(
              url: 'https://jelly.example/stream',
              itemRef: 'jellyfin:jelly.example/$jellyItemId',
              title: 'sample-room',
            ),
          );
        expect(await source.browse(), isEmpty);
        expect(mediaKindForPath('/music/night.FLAC'), MediaKind.audio);
        expect(mediaKindForPath('/videos/movie.mkv'), MediaKind.video);
        expect(mediaKindForPath('/videos/no-extension'), MediaKind.video);
      },
    );

    test('a Jellyfin movie round-trips through its item', () async {
      final session = ShelfSession(server: jellyServer);
      final source = JellyfinMediaSource(
        api: FakeJellyfinApi(saved: session),
        signIn: (_) async => null,
      );
      expect(source.ready, isFalse);
      await source.ensureReady();
      expect(source.ready, isTrue);
      expect(source.account, 'Signed in as root on jelly.example');

      final items = await source.browse();
      expect(items, hasLength(shelfMovies.length));
      final item = items.firstWhere((i) => i.title == 'sample-room');
      expect(item.ref, jellyfinRef(jellyServer, jellyItemId));
      expect(parseJellyfinRef(item.ref)?.itemId, jellyItemId);
      expect(sourceKindOf(item.ref), MediaSourceKind.jellyfin);
      expect(item.source, MediaSourceKind.jellyfin);
      expect(item.kind, MediaKind.video);
      expect(item.duration, const Duration(seconds: 20));
      expect(item.aspect, 2 / 3);
      expect(
        item.posterUrl,
        'https://jelly.example/Items/$jellyItemId/Images/Primary'
        '?maxHeight=300&api_key=fake-token',
      );

      final copy = await source.open(item);
      expect(copy?.isRemote, isTrue);
      expect(copy?.itemRef, item.ref);
      expect(copy?.name, 'sample-room');
      expect(copy?.duration, const Duration(seconds: 20));
      expect(
        copy?.path,
        streamUrl(
          server: '$jellyServer',
          token: 'fake-token',
          itemId: jellyItemId,
        ),
      );
    });

    test('search matches title and subtitle, ignoring case', () async {
      expect(mediaMatches(shelf.first, ''), isTrue);
      expect(mediaMatches(shelf.first, '  bunny '), isTrue);
      expect(mediaMatches(shelf.first, '1.4 gb'), isTrue);
      expect(mediaMatches(shelf.first, 'steel'), isFalse);

      final source = JellyfinMediaSource(
        api: FakeJellyfinApi(saved: ShelfSession(server: jellyServer)),
        signIn: (_) async => null,
      );
      await source.restore();
      expect(
        [for (final i in await source.browse(query: 'STEEL')) i.title],
        ['Tears of Steel'],
      );
    });

    test('the registered sources, in order, with the planned ones listed', () {
      final sources = mediaSources(
        local: LocalMediaSource(pickFile: () async => null),
        jellyfin: JellyfinMediaSource(
          api: FakeJellyfinApi(),
          signIn: (_) async => null,
        ),
      );
      expect(
        [for (final s in sources) s.label],
        ['This computer', 'Jellyfin', 'YouTube', 'Music'],
      );
      expect(
        [for (final s in sources) s.available],
        [true, true, false, false],
      );
      expect(mediaKindBadge(MediaKind.audio).$2, 'Music');
      expect(mediaKindBadge(MediaKind.live).$2, 'Live');
    });
  });

  group('library', () {
    testWidgets('tabs are the registered sources; Soon ones never open', (
      tester,
    ) async {
      final a = FakeSource('Shelf A', items: [film('Only in A')]);
      final b = FakeSource(
        'Shelf B',
        items: [film('Only in B')],
        kind: MediaSourceKind.jellyfin,
      );
      await openLibrary(
        tester,
        sources: [
          a,
          const SoonMediaSource(MediaSourceKind.youtube, 'YouTube'),
          b,
        ],
      );
      final xs = [
        for (final label in ['Shelf A', 'YouTube', 'Shelf B'])
          tester.getTopLeft(find.text(label)).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));
      expect(find.text('Soon'), findsOneWidget);
      expect(find.text('Only in A'), findsOneWidget);

      await tester.tap(find.text('YouTube'));
      await settle(tester);
      expect(find.text('Only in A'), findsOneWidget);

      await tester.tap(find.text('Shelf B'));
      await settle(tester);
      expect(find.text('Only in B'), findsOneWidget);
      expect(find.text('Only in A'), findsNothing);
    });

    testWidgets('opens on the requested tab, or the first available one', (
      tester,
    ) async {
      await openLibrary(
        tester,
        sources: [
          FakeSource('Shelf A', items: [film('Only in A')]),
          const SoonMediaSource(MediaSourceKind.youtube, 'YouTube'),
        ],
        initial: MediaSourceKind.youtube,
      );
      expect(find.text('Only in A'), findsOneWidget);
    });

    testWidgets('search filters, and says so when nothing matches', (
      tester,
    ) async {
      await openLibrary(tester, sources: [FakeSource('Shelf', items: shelf)]);
      expect(find.text('Sintel'), findsOneWidget);
      expect(find.text('Tears of Steel'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'steel');
      await settle(tester);
      expect(find.text('Tears of Steel'), findsOneWidget);
      expect(find.text('Sintel'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await settle(tester);
      expect(find.text('No matches for “zzz”'), findsOneWidget);

      await tester.tap(find.widgetWithText(WtButton, 'Clear search'));
      await settle(tester);
      expect(find.text('Sintel'), findsOneWidget);
      expect(find.text('Tears of Steel'), findsOneWidget);
    });

    testWidgets('each card carries its kind badge', (tester) async {
      await openLibrary(tester, sources: [FakeSource('Shelf', items: shelf)]);
      expect(find.byTooltip('Film'), findsNWidgets(3));
      expect(find.byTooltip('Music'), findsOneWidget);
      expect(find.byTooltip('Live'), findsOneWidget);
    });

    testWidgets('not signed in offers Connect, which signs in and browses', (
      tester,
    ) async {
      final previous = <JellyfinSession?>[];
      final jellyfin = JellyfinMediaSource(
        api: FakeJellyfinApi(),
        signIn: (p) async {
          previous.add(p);
          return ShelfSession(server: jellyServer);
        },
      );
      await openLibrary(tester, sources: [jellyfin]);
      expect(find.text('Not signed in to Jellyfin'), findsOneWidget);
      expect(find.text('Big Buck Bunny'), findsNothing);

      await tester.tap(find.widgetWithText(WtButton, 'Connect Jellyfin'));
      await settle(tester);
      expect(previous, [null]);
      expect(find.text('Not signed in to Jellyfin'), findsNothing);
      expect(find.text('Signed in as root on jelly.example'), findsOneWidget);
      expect(find.text('Big Buck Bunny'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signed in but empty says so, with the source actions', (
      tester,
    ) async {
      final local = LocalMediaSource(pickFile: () async => null);
      final jellyfin = JellyfinMediaSource(
        api: FakeJellyfinApi(
          saved: ShelfSession(server: jellyServer, shelf: const []),
        ),
        signIn: (_) async => null,
      );
      await jellyfin.restore();
      await openLibrary(tester, sources: [local, jellyfin]);
      expect(find.text('Nothing in this library yet'), findsOneWidget);
      expect(find.text(local.emptyHint), findsOneWidget);
      expect(find.widgetWithText(WtButton, 'Choose file…'), findsOneWidget);

      await tester.tap(find.text('Jellyfin'));
      await settle(tester);
      expect(find.text('Nothing in this library yet'), findsOneWidget);
      expect(find.text(jellyfin.emptyHint), findsOneWidget);
      expect(find.widgetWithText(WtButton, 'Change'), findsOneWidget);
    });

    testWidgets('Play closes with the picked copy', (tester) async {
      final result = await openLibrary(
        tester,
        sources: [FakeSource('Shelf', items: shelf)],
      );
      expect(find.widgetWithText(WtButton, 'Play'), findsNothing);
      await tester.tap(find.text('Sintel'));
      await tester.pump();
      await tester.tap(find.widgetWithText(WtButton, 'Play'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsNothing);
      expect((await result)?.itemRef, shelf[1].ref);
    });

    testWidgets('queue mode queues each pick and stays open', (tester) async {
      final queued = <MediaItem>[];
      final result = await openLibrary(
        tester,
        sources: [FakeSource('Shelf', items: shelf)],
        mode: LibraryMode.queue,
        onQueue: queued.add,
      );
      expect(find.text('Add to queue'), findsOneWidget);

      await tester.tap(find.text('Sintel'));
      await tester.pump();
      expect(find.widgetWithText(WtButton, 'Play'), findsNothing);
      await tester.tap(find.widgetWithText(WtButton, 'Queue this'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsOneWidget);
      expect([for (final i in queued) i.title], ['Sintel']);
      expect(find.text('1 queued'), findsOneWidget);

      await tester.tap(find.text('Big Buck Bunny'));
      await tester.pump();
      await tester.tap(find.widgetWithText(WtButton, 'Queue this'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsOneWidget);
      expect([for (final i in queued) i.title], ['Sintel', 'Big Buck Bunny']);
      expect(find.text('2 queued'), findsOneWidget);

      // A queued card cannot be queued twice.
      await tester.tap(find.text('Sintel'));
      await tester.pump();
      final again = tester.widget<WtButton>(
        find.widgetWithText(WtButton, 'Queued'),
      );
      expect(again.onPressed, isNull);

      await tester.tap(find.widgetWithText(WtButton, 'Done'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsNothing);
      expect(await result, isNull);
      expect(queued, hasLength(2));
    });

    testWidgets('a source action in queue mode queues what it picked', (
      tester,
    ) async {
      final queued = <MediaItem>[];
      await openLibrary(
        tester,
        sources: [LocalMediaSource(pickFile: () async => hostCopy)],
        mode: LibraryMode.queue,
        onQueue: queued.add,
      );
      await tester.tap(find.widgetWithText(WtButton, 'Choose file…'));
      await settle(tester);
      expect(find.byType(MediaLibrary), findsOneWidget);
      expect([for (final i in queued) i.ref], [hostRef]);
      expect(find.text('movie-night_1080p.mkv'), findsOneWidget);
    });

    group('keyboard', () {
      testWidgets('/ focuses search, Down enters the grid, arrows move, Enter '
          'plays', (tester) async {
        final result = await openLibrary(
          tester,
          sources: [FakeSource('Shelf', items: shelf)],
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.slash);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'library search',
        );
        // The `/` itself is not typed into the field.
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          isEmpty,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'library');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(find.byType(MediaLibrary), findsNothing);
        expect((await result)?.itemRef, shelf[1].ref);
      });

      testWidgets('Down from the top row moves a whole row', (tester) async {
        final many = [for (var i = 0; i < 12; i++) film('Episode $i')];
        final result = await openLibrary(
          tester,
          sources: [FakeSource('Shelf', items: many)],
        );
        double top(int i) => tester.getTopLeft(find.text('Episode $i')).dy;
        var columns = 1;
        while (top(columns) == top(0)) {
          columns++;
        }
        expect(columns, lessThan(many.length));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect((await result)?.itemRef, many[columns].ref);
      });

      testWidgets('Enter in queue mode queues and stays open', (tester) async {
        final queued = <MediaItem>[];
        await openLibrary(
          tester,
          sources: [FakeSource('Shelf', items: shelf)],
          mode: LibraryMode.queue,
          onQueue: queued.add,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect([for (final i in queued) i.title], ['Big Buck Bunny']);
        expect(find.byType(MediaLibrary), findsOneWidget);
      });

      testWidgets('Esc closes with nothing picked', (tester) async {
        final result = await openLibrary(
          tester,
          sources: [FakeSource('Shelf', items: shelf)],
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.slash);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byType(MediaLibrary), findsNothing);
        expect(await result, isNull);
      });
    });
  });
}
