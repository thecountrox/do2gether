# TASK: the media library (own section, source-agnostic)

The pick flow is still a pair of text links inside the join card: `Choose file…` and `Jellyfin`. That
was enough to prove sync; it is not where media should live. Give picking its own section — a browse
surface that shows what is available, feels like a library, and is built to carry music and YouTube
next without being rebuilt.

## Shape

**A. Model first (this is the part that must survive).**

```
enum MediaKind { video, audio, live }        // live = a stream/URL
enum MediaSourceKind { local, jellyfin, youtube, ytm }

class MediaItem {
  String ref;                 // the item_ref that goes on the wire, unchanged
  String title;
  String? subtitle;           // artist/album, show/season, channel
  MediaKind kind;
  MediaSourceKind source;
  Duration? duration;
  String? posterUrl;          // http(s) for Jellyfin; null for local files
  double? aspect;             // poster vs square art later
}

abstract class MediaSource {
  MediaSourceKind get kind;
  String get label;                       // "This computer", "Jellyfin", "YouTube"
  bool get ready;                          // signed in / available
  Future<List<MediaItem>> browse({String query = ''});
  Future<void> ensureReady();             // sign-in flow, if any
}
```

`ref` is what the room already understands (`file:sha256p:…`, `jellyfin:<host>/<id>`), so nothing on the
server or in the sync engine changes. Music will add `subsonic:…`/`ytm:…` refs later — the UI must
never assume video.

**B. The library screen.**

- Full-height surface with its own header: title, a search field, and source tabs built from the
  registered sources (`This computer`, `Jellyfin`, and — visibly disabled with a `Soon` tag —
  `YouTube`, `Music`). Do not hard-code the tabs; iterate the source list.
- Content: a responsive grid of cards. Jellyfin items show their poster (`{server}/Items/{id}/Images/
  Primary?maxHeight=300&api_key=…`, verified working); local files show a file glyph plus the size and
  runtime. Card shows title, subtitle, duration; hover reveals `Play` and `Queue` actions.
- Empty states per source: not signed in (`Connect Jellyfin`), signed in but empty (`Nothing in this
  library yet`), and no search results.
- Keyboard: `/` focuses search, `Esc` closes, arrows move, `Enter` plays. Pointer does everything too.
- One badge per card for the kind (film / note / broadcast) so music and live items are legible before
  the adapters exist.

**C. Where it is reachable from.**

- Home: replace `Choose file…` / `Jellyfin` inline links with one `Pick media` action that opens the
  library; keep drag-and-drop of a local file as the fast path. Choosing an item sets the room copy the
  same way today's pickers do.
- Room: the queue's `Add` opens the library in **queue mode** (a `Queue this` action instead of `Play`,
  and no closing on pick so several can be added).
- A `Library` entry in the Home brand column so the section is reachable on its own, not only mid-join.

**D. Diagrams of intent, not a rewrite.** The existing Jellyfin dialog becomes the sign-in form inside
the library's Jellyfin source (`ensureReady`). Local file picking stays the OS dialog when the user has
no library to browse.

## Constraints

- No protocol, clock, drift, or intent changes; `item_ref` formats stay as they are.
- Candy palette and the existing widget vocabulary; no new fonts or packages.
- Tests: model/ref round-trip for both sources, tab list honours registered sources, search filters,
  empty states, queue mode does not close on pick, and the keyboard paths. Goldens: library with
  Jellyfin posters and library in queue mode, at 1440×900 and 856×1038.
- `flutter test` green, `flutter analyze` no new issues, `flutter build linux --debug` passes.

## Do not

- Do not invent a YouTube or music adapter in this pass. Disabled tabs and the model are the whole
  point; shipping a stub that lies is worse than an honest `Soon`.

Report: the model as built, how sources register, screenshots/golden paths, test count, and the parts you
deliberately deferred.
