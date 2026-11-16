/// What the library browses. Every item is carried by the `item_ref` the room already speaks, so a
/// new source is one more [MediaSource] in [mediaSources] and nothing on the wire changes.
library;

import 'package:flutter/material.dart';

import 'format.dart';
import 'jellyfin.dart';
import 'local_copy.dart';

/// `live` is a stream or URL with no fixed end.
enum MediaKind { video, audio, live }

enum MediaSourceKind { local, jellyfin, youtube, ytm }

/// Read off the ref alone, so a queue row's source always matches what will open.
MediaSourceKind sourceKindOf(String ref) => ref.startsWith('jellyfin:')
    ? MediaSourceKind.jellyfin
    : MediaSourceKind.local;

class MediaItem {
  const MediaItem({
    required this.ref,
    required this.title,
    required this.kind,
    required this.source,
    this.subtitle,
    this.duration,
    this.posterUrl,
    this.aspect,
  });

  /// The `item_ref` that goes on the wire, unchanged.
  final String ref;
  final String title;

  /// Artist/album, show/season, channel; a local file's size.
  final String? subtitle;
  final MediaKind kind;
  final MediaSourceKind source;
  final Duration? duration;

  /// http(s) art; null for local files.
  final String? posterUrl;

  /// Width over height of the art: 2/3 for posters, 1 for album art; null when there is none.
  final double? aspect;
}

/// Case-insensitive match on title and subtitle; an empty query matches everything.
bool mediaMatches(MediaItem item, String query) {
  final q = query.trim().toLowerCase();
  return q.isEmpty ||
      item.title.toLowerCase().contains(q) ||
      (item.subtitle?.toLowerCase().contains(q) ?? false);
}

/// Something a source offers besides browsing: `Choose file…`, `Change` account.
class MediaSourceAction {
  const MediaSourceAction({
    required this.label,
    required this.icon,
    required this.run,
  });
  final String label;
  final IconData icon;

  /// Resolves to an item to play or queue straight away, or null when there is nothing to pick.
  final Future<MediaItem?> Function() run;
}

abstract class MediaSource {
  const MediaSource();

  MediaSourceKind get kind;

  /// Tab label: `This computer`, `Jellyfin`, `YouTube`.
  String get label;

  /// Signed in / available. False shows the connect state instead of a grid.
  bool get ready;

  Future<List<MediaItem>> browse({String query = ''});

  /// The sign-in flow, if any. May show UI, so only call it from a user action.
  Future<void> ensureReady();

  /// Picks up credentials already saved on this machine, without prompting. Safe to call from a
  /// background refresh; the default does nothing.
  Future<void> restoreSaved() async {}

  /// False lists the source with a `Soon` tag and never selects it.
  bool get available => true;

  /// Who the source is signed in as, for the library header.
  String? get account => null;

  /// The second line of `Nothing in this library yet`.
  String get emptyHint => 'Nothing to show from ${label.toLowerCase()} yet.';

  List<MediaSourceAction> get actions => const [];

  /// The playable copy behind an item from [browse]; null when it can no longer be opened.
  Future<LocalCopy?> open(MediaItem item);
}

/// The library's tabs, in order. A new adapter is one more entry here.
List<MediaSource> mediaSources({
  required LocalMediaSource local,
  required JellyfinMediaSource jellyfin,
}) => [
  local,
  jellyfin,
  const SoonMediaSource(MediaSourceKind.youtube, 'YouTube'),
  const SoonMediaSource(MediaSourceKind.ytm, 'Music'),
];

const Set<String> _audioExtensions = {
  'aac',
  'aiff',
  'alac',
  'flac',
  'm4a',
  'mp3',
  'oga',
  'ogg',
  'opus',
  'wav',
  'wma',
};

/// Audio by extension, video otherwise: a picked `.flac` must not be badged as a film.
MediaKind mediaKindForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return _audioExtensions.contains(ext) ? MediaKind.audio : MediaKind.video;
}

/// Files on this computer. There is no folder to scan: the list is what was opened this session,
/// and `Choose file…` is the OS dialog.
class LocalMediaSource extends MediaSource {
  LocalMediaSource({this.pickFile = pickLocalCopy});

  /// Asks for a file, hashes and probes it.
  final PickCopy pickFile;
  final List<LocalCopy> _recent = [];

  @override
  MediaSourceKind get kind => MediaSourceKind.local;

  @override
  String get label => 'This computer';

  @override
  bool get ready => true;

  @override
  String get emptyHint =>
      'Files you open show up here. There is no folder to scan: pick one.';

  @override
  Future<void> ensureReady() async {}

  /// Puts [copy] first; remote copies belong to their own source.
  void remember(LocalCopy copy) {
    if (copy.isRemote) return;
    _recent
      ..removeWhere((c) => c.itemRef == copy.itemRef)
      ..insert(0, copy);
  }

  /// The OS dialog; a picked file is remembered here.
  Future<LocalCopy?> pick() async {
    final copy = await pickFile();
    if (copy != null) remember(copy);
    return copy;
  }

  static MediaItem itemFor(LocalCopy copy) => MediaItem(
    ref: copy.itemRef,
    title: copy.name,
    subtitle: fmtBytes(copy.bytes),
    kind: mediaKindForPath(copy.path),
    source: MediaSourceKind.local,
    duration: copy.duration,
  );

  @override
  Future<List<MediaItem>> browse({String query = ''}) async => [
    for (final copy in _recent)
      if (itemFor(copy) case final item when mediaMatches(item, query)) item,
  ];

  @override
  List<MediaSourceAction> get actions => [
    MediaSourceAction(
      label: 'Choose file…',
      icon: Icons.folder_open_rounded,
      run: () async {
        final copy = await pick();
        return copy == null ? null : itemFor(copy);
      },
    ),
  ];

  @override
  Future<LocalCopy?> open(MediaItem item) async {
    for (final copy in _recent) {
      if (copy.itemRef == item.ref) return copy;
    }
    return null;
  }
}

/// Movies on the viewer's own Jellyfin. Each viewer streams with their own token; the room only
/// sees `jellyfin:<host>/<itemId>`.
class JellyfinMediaSource extends MediaSource {
  JellyfinMediaSource({required this.api, required this.signIn});

  final JellyfinApi api;

  /// The sign-in form, pre-filled from [previous]; resolves to the new session, or null when closed.
  final Future<JellyfinSession?> Function(JellyfinSession? previous) signIn;

  JellyfinSession? _session;

  /// Kept after the session is dropped, so the form opens on the same server and user.
  JellyfinSession? _previous;
  List<JellyfinItem>? _movies;
  Future<void>? _restoring;

  JellyfinSession? get session => _session;

  @override
  MediaSourceKind get kind => MediaSourceKind.jellyfin;

  @override
  String get label => 'Jellyfin';

  @override
  bool get ready => _session != null;

  @override
  String get emptyHint => 'Movies added to your Jellyfin server show up here.';

  @override
  String? get account => switch (_session) {
    final s? => 'Signed in as ${s.user} on ${s.server.host}',
    null => null,
  };

  @override
  Future<void> restoreSaved() => restore();

  /// Picks up the sign-in saved on this machine, once — and is awaitable by every caller, so a
  /// library asked to browse mid-restore waits for the answer instead of reading "not signed in".
  Future<void> restore() => _restoring ??= _restoreOnce();

  Future<void> _restoreOnce() async {
    try {
      final saved = await api.restore();
      if (_session == null && saved != null) _use(saved);
    } on Object {
      // Nothing saved that parses; the library offers to connect.
    }
  }

  void _use(JellyfinSession session) {
    _session = _previous = session;
    _movies = null;
  }

  @override
  Future<void> ensureReady() async {
    await restore();
    if (_session != null) return;
    final session = await signIn(_previous);
    if (session != null) _use(session);
  }

  @override
  List<MediaSourceAction> get actions => [
    if (_session != null)
      MediaSourceAction(
        label: 'Change',
        icon: Icons.swap_horiz_rounded,
        run: () async {
          final session = await signIn(_session);
          if (session != null) _use(session);
          return null;
        },
      ),
  ];

  static MediaItem itemFor(JellyfinSession session, JellyfinItem movie) =>
      MediaItem(
        ref: jellyfinRef(session.server, movie.id),
        title: movie.name,
        kind: MediaKind.video,
        source: MediaSourceKind.jellyfin,
        duration: movie.runtime,
        posterUrl: posterUrl(
          server: '${session.server}',
          token: session.token,
          itemId: movie.id,
        ),
        aspect: 2 / 3,
      );

  /// An unfiltered browse fetches afresh; typing filters what was fetched.
  @override
  Future<List<MediaItem>> browse({String query = ''}) async {
    final session = _session;
    if (session == null) return const [];
    try {
      final movies = query.trim().isEmpty || _movies == null
          ? _movies = await session.movies()
          : _movies!;
      return [
        for (final movie in movies)
          if (itemFor(session, movie) case final item
              when mediaMatches(item, query))
            item,
      ];
    } on JellyfinException catch (e) {
      // A saved token can be revoked: drop it so the library asks to connect again.
      if (e.status == 401 && identical(_session, session)) _session = null;
      rethrow;
    }
  }

  @override
  Future<LocalCopy?> open(MediaItem item) async {
    final session = _session;
    final parts = parseJellyfinRef(item.ref);
    if (session == null || parts == null) return null;
    return LocalCopy.remote(
      url: streamUrl(
        server: '${session.server}',
        token: session.token,
        itemId: parts.itemId,
      ),
      itemRef: item.ref,
      title: item.title,
      duration: item.duration,
    );
  }
}

/// Planned, not built: listed with a `Soon` tag so the shape is visible, never browsed.
class SoonMediaSource extends MediaSource {
  const SoonMediaSource(this.kind, this.label);

  @override
  final MediaSourceKind kind;

  @override
  final String label;

  @override
  bool get ready => false;

  @override
  bool get available => false;

  @override
  Future<List<MediaItem>> browse({String query = ''}) async => const [];

  @override
  Future<void> ensureReady() async {}

  @override
  Future<LocalCopy?> open(MediaItem item) async => null;
}
