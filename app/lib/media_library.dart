/// The library: one full-height surface for picking what to play or queue. Tabs, cards and empty
/// states are built from the registered [MediaSource]s, so a new source is a new tab and nothing
/// here changes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'local_copy.dart';
import 'media.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';

/// `play` closes on the first pick with that item's copy; `queue` hands every pick to `onQueue` and
/// stays open so several can be added.
enum LibraryMode { play, queue }

/// Art for a poster URL; tests swap in memory images.
typedef PosterImage = ImageProvider Function(String url);

ImageProvider networkPoster(String url) => NetworkImage(url);

/// Resolves to the picked item's copy in [LibraryMode.play]; null when closed, and always null in
/// [LibraryMode.queue].
Future<LocalCopy?> showMediaLibrary(
  BuildContext context, {
  required List<MediaSource> sources,
  LibraryMode mode = LibraryMode.play,
  MediaSourceKind? initial,
  ValueChanged<MediaItem>? onQueue,
  PosterImage poster = networkPoster,
}) => Navigator.of(context).push<LocalCopy>(
  wtRoute(
    MediaLibrary(
      sources: sources,
      mode: mode,
      initial: initial,
      onQueue: onQueue,
      poster: poster,
    ),
  ),
);

class MediaLibrary extends StatefulWidget {
  const MediaLibrary({
    super.key,
    required this.sources,
    this.mode = LibraryMode.play,
    this.initial,
    this.onQueue,
    this.poster = networkPoster,
  }) : assert(mode == LibraryMode.play || onQueue != null);

  /// The tabs, in order.
  final List<MediaSource> sources;
  final LibraryMode mode;

  /// The tab to open on; the first available source when null or not available.
  final MediaSourceKind? initial;

  /// Adds an item to the room's queue. In play mode a non-null value puts `Queue` beside `Play`.
  final ValueChanged<MediaItem>? onQueue;
  final PosterImage poster;

  @override
  State<MediaLibrary> createState() => _MediaLibraryState();
}

class _MediaLibraryState extends State<MediaLibrary> {
  final _query = TextEditingController();
  final _search = FocusNode(debugLabel: 'library search');
  final _keys = FocusNode(debugLabel: 'library');
  final _scroll = ScrollController();
  late int _tab = _initialTab();

  /// Null while the tab loads.
  List<MediaItem>? _items;
  Object? _error;
  int _seq = 0;
  int? _selected;

  /// The ref being opened, or the label of the action running; other actions wait for it.
  String? _busy;
  final Set<String> _queued = {};
  int _columns = 1;
  double _rowExtent = 0;

  static const _connecting = 'connect';
  static const _muted = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w600,
    color: WtColors.tx3,
  );

  bool get _queueMode => widget.mode == LibraryMode.queue;
  MediaSource get _source => widget.sources[_tab];

  /// `Nothing in this library yet`: the empty state carries the source's actions, so the toolbar
  /// leaves them out.
  bool get _emptyLibrary =>
      _source.ready &&
      _error == null &&
      (_items?.isEmpty ?? false) &&
      _query.text.trim().isEmpty;

  int _initialTab() {
    final sources = widget.sources;
    final wanted = sources.indexWhere(
      (s) => s.kind == widget.initial && s.available,
    );
    if (wanted >= 0) return wanted;
    return math.max(0, sources.indexWhere((s) => s.available));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _query.dispose();
    _search.dispose();
    _keys.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// [fresh] blanks the grid while it loads (a tab switch); a search keeps the old cards up until
  /// the new ones arrive.
  void _reload({bool fresh = true}) {
    setState(() {
      if (fresh) _items = null;
      _error = null;
      _selected = null;
    });
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final source = _source;
    final seq = ++_seq;
    try {
      final items = source.available && source.ready
          ? await source.browse(query: _query.text)
          : const <MediaItem>[];
      if (mounted && seq == _seq) setState(() => _items = items);
    } on Object catch (e) {
      if (mounted && seq == _seq) {
        setState(() {
          _items = const [];
          _error = e;
        });
      }
    }
  }

  void _pickTab(int i) {
    if (i == _tab || !widget.sources[i].available) return;
    _tab = i;
    _reload();
  }

  void _say(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _connect() async {
    final source = _source;
    setState(() => _busy = _connecting);
    try {
      await source.ensureReady();
    } on Object catch (e) {
      if (mounted) _say("Couldn't connect ${source.label}: $e");
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (mounted && identical(source, _source)) _reload();
  }

  Future<void> _run(MediaSourceAction action) async {
    setState(() => _busy = action.label);
    MediaItem? item;
    try {
      item = await action.run();
    } on Object catch (e) {
      if (mounted) _say("Couldn't open that: $e");
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    _reload(fresh: false);
    if (item != null) await _primary(item);
  }

  /// `Play` or `Queue this`, whichever the mode makes the main action.
  Future<void> _primary(MediaItem item) async {
    if (_queueMode) {
      _queue(item);
    } else {
      await _play(item);
    }
  }

  void _queue(MediaItem item) {
    widget.onQueue!(item);
    setState(() => _queued.add(item.ref));
  }

  Future<void> _play(MediaItem item) async {
    final source = widget.sources.firstWhere((s) => s.kind == item.source);
    setState(() => _busy = item.ref);
    try {
      final copy = await source.open(item);
      if (!mounted) return;
      if (copy == null) {
        _say("Couldn't open ${item.title} any more. Pick it again.");
        return;
      }
      Navigator.of(context).pop(copy);
    } on Object catch (e) {
      if (mounted) _say("Couldn't open ${item.title}: $e");
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _select(int i) {
    setState(() => _selected = i);
    if (!_scroll.hasClients || _rowExtent <= 0) return;
    final pos = _scroll.position;
    final top = (i ~/ _columns) * _rowExtent;
    final bottom = top + _rowExtent;
    final target = top < pos.pixels
        ? top
        : bottom > pos.pixels + pos.viewportDimension
        ? bottom - pos.viewportDimension
        : null;
    if (target != null) {
      _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
    }
  }

  void _close() => unawaited(Navigator.of(context).maybePop());

  /// `/` search, `Esc` close; arrows and `Enter` only while the grid itself has focus, so a focused
  /// button or the search field keeps its own keys.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    final typing = _search.hasFocus;
    if (key == LogicalKeyboardKey.slash && !typing) {
      _search.requestFocus();
      return KeyEventResult.handled;
    }
    final items = _items ?? const <MediaItem>[];
    if (items.isEmpty) return KeyEventResult.ignored;
    if (typing && key == LogicalKeyboardKey.arrowDown) {
      _keys.requestFocus();
      _select(_selected ?? 0);
      return KeyEventResult.handled;
    }
    if (!_keys.hasPrimaryFocus) return KeyEventResult.ignored;
    final step = key == LogicalKeyboardKey.arrowLeft
        ? -1
        : key == LogicalKeyboardKey.arrowRight
        ? 1
        : key == LogicalKeyboardKey.arrowUp
        ? -_columns
        : key == LogicalKeyboardKey.arrowDown
        ? _columns
        : 0;
    final current = _selected;
    if (step != 0) {
      _select(
        current == null ? 0 : (current + step).clamp(0, items.length - 1),
      );
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        current != null) {
      if (_busy == null) unawaited(_primary(items[current]));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => WtScaffold(
    child: Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: WtBackdrop(
        child: Padding(
          padding: const EdgeInsets.all(WtSpace.window),
          child: LayoutBuilder(
            builder: (context, box) {
              final narrow = box.maxWidth < 1000;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(narrow),
                  const SizedBox(height: 20),
                  _tabs(narrow),
                  const SizedBox(height: 18),
                  Expanded(child: _body()),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _header(bool narrow) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _queueMode ? 'Add to queue' : 'Library',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 4),
        Text(
          _queueMode
              ? 'Queue as many as you like. Each one goes to the end.'
              : 'Pick what you will play. Everyone opens their own copy.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _muted,
        ),
      ],
    );
    final search = WtField(
      controller: _query,
      focusNode: _search,
      hint: 'Search',
      icon: Icons.search_rounded,
      height: 52,
      onChanged: (_) => _reload(fresh: false),
      onSubmitted: (_) {
        if (_items?.isNotEmpty ?? false) {
          _keys.requestFocus();
          _select(_selected ?? 0);
        }
      },
      trailing: const _KeyHint('/'),
    );
    final end = [
      if (_queueMode && _queued.isNotEmpty) ...[
        WtPill(
          label: '${_queued.length} queued',
          tone: WtTone.live,
          icon: Icons.check_rounded,
          fontSize: 13,
        ),
        const SizedBox(width: 12),
      ],
      if (_queueMode)
        WtButton(label: 'Done', onPressed: _close)
      else
        WtIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close (Esc)',
          onPressed: _close,
        ),
    ];
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 16),
              ...end,
            ],
          ),
          const SizedBox(height: 16),
          search,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: title),
        const SizedBox(width: 24),
        SizedBox(width: 380, child: search),
        const SizedBox(width: 16),
        ...end,
      ],
    );
  }

  Widget _tabs(bool narrow) {
    final source = _source;
    final tabs = [
      for (final (i, s) in widget.sources.indexed) ...[
        if (i > 0) const SizedBox(width: 8),
        _SourceTab(
          source: s,
          selected: i == _tab,
          onTap: s.available ? () => _pickTab(i) : null,
        ),
      ],
    ];
    final extras = [
      if (source.account case final account?)
        Flexible(
          child: Text(
            account,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _muted.copyWith(fontSize: 13),
          ),
        ),
      if (!_emptyLibrary)
        for (final action in source.actions)
          WtTextButton(
            label: _busy == action.label ? 'Checking…' : action.label,
            icon: action.icon,
            compact: true,
            onPressed: _busy == null ? () => _run(action) : null,
          ),
    ];
    if (!narrow) return Row(children: [...tabs, const Spacer(), ...extras]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: tabs),
        ),
        if (extras.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: extras),
        ],
      ],
    );
  }

  Widget _body() {
    final source = _source;
    final items = _items;
    final error = _error;
    if (!source.ready) {
      return _EmptyState(
        icon: Icons.link_rounded,
        title: 'Not signed in to ${source.label}',
        body: error == null
            ? 'Sign in to browse it here. The room only ever shares which item, '
                  'never your account.'
            : '$error',
        actions: [
          WtButton(
            label: _busy == _connecting
                ? 'Connecting…'
                : 'Connect ${source.label}',
            icon: Icons.login_rounded,
            onPressed: _busy == null ? _connect : null,
          ),
        ],
      );
    }
    if (items == null) return _Loading(label: 'Loading ${source.label}…');
    if (error != null) {
      return _EmptyState(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load ${source.label}",
        body: '$error',
        actions: [
          WtButton(
            label: 'Try again',
            style: WtButtonStyle.ghost,
            onPressed: _reload,
          ),
        ],
      );
    }
    final query = _query.text.trim();
    if (items.isEmpty && query.isNotEmpty) {
      return _EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches for “$query”',
        body: 'Try another word, or clear the search.',
        actions: [
          WtButton(
            label: 'Clear search',
            style: WtButtonStyle.ghost,
            onPressed: () {
              _query.clear();
              _reload(fresh: false);
            },
          ),
        ],
      );
    }
    if (_emptyLibrary) {
      return _EmptyState(
        icon: Icons.video_library_outlined,
        title: 'Nothing in this library yet',
        body: source.emptyHint,
        actions: [
          for (final action in source.actions)
            WtButton(
              label: _busy == action.label ? 'Checking…' : action.label,
              icon: action.icon,
              onPressed: _busy == null ? () => _run(action) : null,
            ),
        ],
      );
    }
    return _grid(items);
  }

  Widget _grid(List<MediaItem> items) => LayoutBuilder(
    builder: (context, box) {
      const gap = 18.0;
      const minTile = 168.0;
      const text = 58.0;
      // Room for the focus ring, which sits 5px outside the art.
      const edge = 6.0;
      final width = box.maxWidth - 2 * edge;
      final columns = ((width + gap) / (minTile + gap)).floor().clamp(2, 8);
      final tile = (width - gap * (columns - 1)) / columns;
      final extent = tile * 1.5 + text;
      _columns = columns;
      _rowExtent = extent + gap;
      return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(edge),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          mainAxisExtent: extent,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return _MediaCard(
            item: item,
            poster: widget.poster,
            selected: i == _selected,
            queued: _queued.contains(item.ref),
            busy: _busy == item.ref,
            queueMode: _queueMode,
            onSelect: () {
              _keys.requestFocus();
              setState(() => _selected = i);
            },
            onPlay: _queueMode || _busy != null ? null : () => _play(item),
            onQueue: widget.onQueue == null ? null : () => _queue(item),
          );
        },
      );
    },
  );
}

class _KeyHint extends StatelessWidget {
  const _KeyHint(this.key_);
  final String key_;

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    margin: const EdgeInsets.only(right: 6),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: WtColors.s1,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: WtColors.line, width: 1.5),
    ),
    child: Text(
      key_,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: WtColors.tx3,
      ),
    ),
  );
}

/// A source's tab: pink outline when selected; dimmed with `Soon` when the source is planned only.
class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.source,
    required this.selected,
    required this.onTap,
  });
  final MediaSource source;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final soon = !source.available;
    Widget tab = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: selected ? WtColors.s2 : WtColors.s1,
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: Border.all(
          color: selected ? WtColors.pink : WtColors.line,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            source.label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: soon ? WtColors.tx3 : WtColors.text,
            ),
          ),
          if (soon) ...[const SizedBox(width: 8), const _SoonTag()],
        ],
      ),
    );
    if (soon) tab = Opacity(opacity: 0.6, child: tab);
    return Semantics(
      selected: selected,
      child: WtTap(
        onTap: onTap,
        radius: WtRadius.pill,
        dimWhenDisabled: false,
        tooltip: soon ? '${source.label} is coming soon' : null,
        child: tab,
      ),
    );
  }
}

class _SoonTag extends StatelessWidget {
  const _SoonTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: WtColors.yellow, width: 1.5),
    ),
    child: const Text(
      'Soon',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: WtColors.yellow,
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
  });
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: WtColors.s1,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: WtColors.line, width: 2),
              ),
              child: Icon(icon, size: 28, color: WtColors.tx2),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: _MediaLibraryState._muted,
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 18),
              Wrap(spacing: 10, runSpacing: 10, children: actions),
            ],
          ],
        ),
      ),
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const WtDot(color: WtColors.cyan, style: WtDotStyle.pulse),
        const SizedBox(width: 10),
        Text(label, style: _MediaLibraryState._muted),
      ],
    ),
  );
}

/// Film, note or broadcast, so music and live items read right before their adapters exist.
(IconData, String) mediaKindBadge(MediaKind kind) => switch (kind) {
  MediaKind.video => (Icons.movie_outlined, 'Film'),
  MediaKind.audio => (Icons.music_note_rounded, 'Music'),
  MediaKind.live => (Icons.sensors_rounded, 'Live'),
};

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = mediaKindBadge(kind);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xCC1A0E27),
            shape: BoxShape.circle,
            border: Border.all(color: WtColors.line, width: 1.5),
          ),
          child: Icon(icon, size: 16, color: WtColors.tx2),
        ),
      ),
    );
  }
}

/// Title, subtitle and duration under the art; `Play` / `Queue` over it on hover or selection.
class _MediaCard extends StatefulWidget {
  const _MediaCard({
    required this.item,
    required this.poster,
    required this.selected,
    required this.queued,
    required this.busy,
    required this.queueMode,
    required this.onSelect,
    required this.onPlay,
    required this.onQueue,
  });
  final MediaItem item;
  final PosterImage poster;
  final bool selected;
  final bool queued;

  /// This item is opening: `Play` reads `Opening…`.
  final bool busy;
  final bool queueMode;
  final VoidCallback onSelect;

  /// Null hides `Play` in queue mode and disables it while something else opens.
  final VoidCallback? onPlay;

  /// Null hides `Queue` where there is no queue to add to.
  final VoidCallback? onQueue;

  @override
  State<_MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<_MediaCard> {
  bool _hover = false;

  void _setHover(bool value) {
    if (_hover != value) setState(() => _hover = value);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final meta = [
      ?item.subtitle,
      if (item.duration case final d?) fmtTime(d.inMilliseconds),
    ].join(' · ');
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Semantics(
          selected: widget.selected,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: WtFocusRing(
                  show: widget.selected,
                  radius: WtRadius.control,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(WtRadius.control),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Art(item: item, poster: widget.poster),
                        Positioned(
                          left: 8,
                          top: 8,
                          child: _KindBadge(kind: item.kind),
                        ),
                        if (widget.queued)
                          const Positioned(
                            right: 8,
                            top: 8,
                            child: WtPill(
                              label: 'Queued',
                              tone: WtTone.live,
                              icon: Icons.check_rounded,
                              height: 26,
                              fontSize: 12,
                            ),
                          ),
                        if (_hover || widget.selected)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _actions(),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: WtColors.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: WtColors.tx3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    final queued = widget.queued;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 28, 8, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x001A0E27), Color(0xE61A0E27)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.queueMode)
            WtButton(
              label: widget.busy ? 'Opening…' : 'Play',
              icon: Icons.play_arrow_rounded,
              size: WtButtonSize.small,
              fullWidth: true,
              onPressed: widget.onPlay,
            ),
          if (!widget.queueMode && widget.onQueue != null)
            const SizedBox(height: 6),
          if (widget.onQueue != null)
            WtButton(
              label: queued
                  ? 'Queued'
                  : widget.queueMode
                  ? 'Queue this'
                  : 'Queue',
              icon: queued ? Icons.check_rounded : Icons.playlist_add_rounded,
              style: widget.queueMode
                  ? WtButtonStyle.primary
                  : WtButtonStyle.ghost,
              size: WtButtonSize.small,
              fullWidth: true,
              onPressed: queued ? null : widget.onQueue,
            ),
        ],
      ),
    );
  }
}

/// The poster, or a glyph on the plum well: a file for local copies, the kind while art loads or
/// when it fails.
class _Art extends StatelessWidget {
  const _Art({required this.item, required this.poster});
  final MediaItem item;
  final PosterImage poster;

  Widget _fallback() => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [WtColors.s2, WtColors.s1],
      ),
    ),
    child: Center(
      child: item.posterUrl != null
          ? Icon(mediaKindBadge(item.kind).$1, size: 40, color: WtColors.tx3)
          : item.kind == MediaKind.audio
          ? const Icon(Icons.audio_file_outlined, size: 48, color: WtColors.tx3)
          : const WtFileGlyph(size: 48),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final url = item.posterUrl;
    if (url == null) return _fallback();
    return ColoredBox(
      color: WtColors.s2,
      child: Image(
        image: poster(url),
        // Posters fill the tile; square art (music, later) sits whole inside it.
        fit: (item.aspect ?? 2 / 3) < 0.9 ? BoxFit.cover : BoxFit.contain,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, sync) =>
            frame == null && !sync ? _fallback() : child,
        errorBuilder: (_, _, _) => _fallback(),
      ),
    );
  }
}
