/// Display helpers shared by Home, the room-ready dialog and Room.
library;

/// Splits a room code into two halves for key caps: `k3f9x2qa` → `k3f9`, `x2qa`.
/// Codes that already carry a dash keep their groups; odd or short codes stay whole.
List<String> codeGroups(String code) {
  final c = code.trim();
  if (c.contains('-')) return c.split('-').where((g) => g.isNotEmpty).toList();
  if (c.length < 4 || c.length.isOdd) return [c];
  return [c.substring(0, c.length ~/ 2), c.substring(c.length ~/ 2)];
}

/// True when the code avoids the characters people mishear when it is read out.
bool codeIsUnambiguous(String code) =>
    !RegExp('[0o1il]', caseSensitive: false).hasMatch(code);

/// `m:ss`, or `h:mm:ss` from one hour.
String fmtTime(int ms) {
  final s = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Time left, `-12:04` style.
String fmtRemaining(int positionMs, int durationMs) =>
    '-${fmtTime(durationMs - positionMs)}';

/// The error card's sentence for a failed open or a player error. Stream URLs carry the viewer's
/// token, so the raw text is never shown.
String playerErrorReason(String raw) {
  final s = raw.toLowerCase();
  final status = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(raw)?.group(1);
  if (status == '401' || status == '403') {
    return 'The server refused the stream (HTTP $status). Sign in to Jellyfin again.';
  }
  if (status != null && s.contains('http')) {
    return 'The server answered HTTP $status. The item may have moved, or the link expired.';
  }
  if (s.contains('no such file') ||
      s.contains('not found') ||
      s.contains('cannot open file') ||
      s.contains('errno = 2')) {
    return 'The file is missing. It may have been moved, renamed or deleted.';
  }
  if (s.contains('codec') ||
      s.contains('decoder') ||
      s.contains('recognize file format') ||
      s.contains('unsupported')) {
    return "This file uses a format or codec the player can't decode.";
  }
  if (s.contains('tcp:') ||
      s.contains('connection') ||
      s.contains('timed out') ||
      s.contains('resolve')) {
    return "Couldn't reach the server that streams this item.";
  }
  if (s.contains('permission denied') || s.contains('errno = 13')) {
    return "The file can't be read: permission denied.";
  }
  return "The player couldn't open this.";
}

/// Spoken form for the seek slider: `12 minutes 4 seconds`.
String fmtTimeWords(int ms) {
  final s = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final parts = [
    if (h > 0) '$h ${h == 1 ? 'hour' : 'hours'}',
    '$m ${m == 1 ? 'minute' : 'minutes'}',
    '${s % 60} ${s % 60 == 1 ? 'second' : 'seconds'}',
  ];
  return parts.join(' ');
}

/// `1.4 GB`, `820 MB`, `12 KB`.
String fmtBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit > 0 && value < 10 ? 1 : 0;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Top-bar sync pill: yellow `N of M ready` until everyone is synced, then `All M in sync`.
String readyPillLabel(int ready, int total) =>
    total > 0 && ready >= total ? 'All $total in sync' : '$ready of $total ready';

/// Splits a file name so the distinguishing tail stays visible when the head is truncated:
/// `movie-night_1080p.mkv` → `movie-night_`, `1080p.mkv`.
(String, String) splitTail(String name) {
  final cut = name.lastIndexOf(RegExp(r'[_\- ]'));
  if (cut > 0 && name.length - cut - 1 <= 14 && cut < name.length - 1) {
    return (name.substring(0, cut + 1), name.substring(cut + 1));
  }
  final tail = name.length <= 10 ? name.length : 10;
  return (name.substring(0, name.length - tail), name.substring(name.length - tail));
}

/// The last path segment, for either separator.
String baseName(String path) => path.split(RegExp(r'[\\/]')).last;
