/// Wire format of protocol/room.schema.json (v1).
///
/// Decoding never throws: malformed JSON, unknown `t`, or a body that does not match the schema
/// all come back as `null`, and the caller ignores them.
library;

import 'dart:convert';
import 'dart:math' as math;

const int protocolVersion = 1;

/// The `item_ref` pattern from protocol/room.schema.json, verbatim.
final RegExp itemRefPattern = RegExp(
  r'^(file:sha256p:[0-9]+:[0-9a-f]{32}:[0-9a-f]{32}|yt:[A-Za-z0-9_-]{11}|ytm:[A-Za-z0-9_-]{11}|subsonic:[a-z0-9-]+/[A-Za-z0-9_-]+|jellyfin:[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9]{32})$',
);

bool isItemRef(String s) => itemRefPattern.hasMatch(s);

/// `paused ? position_ms : position_ms + (now - anchor) * rate`, rounded like JS `Math.round`
/// and clamped at 0. Negative elapsed time (clock estimate behind the anchor) extrapolates
/// backwards.
int positionAt(Playback pb, int serverNowMs) {
  if (pb.paused) return pb.positionMs;
  final advanced = ((serverNowMs - pb.anchorServerMs) * pb.rate + 0.5).floor();
  return math.max(0, pb.positionMs + advanced);
}

/// `{v, t, room, seq, ts, from, id?}`; `t` comes from the [Body].
class Envelope {
  const Envelope({
    required this.room,
    required this.seq,
    required this.ts,
    required this.from,
    this.id,
  });

  final String room;
  final int seq;

  /// Sender's server-time estimate, ms since epoch.
  final int ts;
  final String from;

  /// Request correlation id.
  final String? id;
}

class Message {
  const Message(this.envelope, this.body);

  final Envelope envelope;
  final Body body;
}

String encodeMessage(Envelope env, Body body) => jsonEncode({
  'v': protocolVersion,
  't': body.type,
  'room': env.room,
  'seq': env.seq,
  'ts': env.ts,
  'from': env.from,
  if (env.id != null) 'id': env.id,
  ...body.toJson(),
});

Message? decodeMessage(String raw) {
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final m = _map(json);
  if (m == null || m['v'] != protocolVersion) return null;
  final room = _str(m['room']);
  final seq = _int(m['seq']);
  final ts = _int(m['ts']);
  final from = _str(m['from']);
  final id = m['id'];
  if (room == null || room.isEmpty || room.length > 64) return null;
  if (seq == null || seq < 0 || ts == null) return null;
  if (from == null || from.isEmpty || from.length > 64) return null;
  if (id != null && (id is! String || id.length > 64)) return null;
  final body = switch (m['t']) {
    'hello' => HelloMsg._parse(m),
    'welcome' => WelcomeMsg._parse(m),
    'clock_ping' => ClockPingMsg._parse(m),
    'clock_pong' => ClockPongMsg._parse(m),
    'intent' => IntentMsg._parse(m),
    'state' => StateMsg._parse(m),
    'report' => ReportMsg._parse(m),
    'presence' => PresenceMsg._parse(m),
    'event' => EventMsg._parse(m),
    'reject' => RejectMsg._parse(m),
    _ => null,
  };
  if (body == null) return null;
  return Message(
    Envelope(room: room, seq: seq, ts: ts, from: from, id: id as String?),
    body,
  );
}

// ---- shared shapes ----

class Playback {
  const Playback({
    required this.itemRef,
    required this.anchorServerMs,
    required this.positionMs,
    required this.rate,
    required this.paused,
  });

  final String itemRef;

  /// Server time at which [positionMs] was true.
  final int anchorServerMs;
  final int positionMs;
  final double rate;
  final bool paused;

  Map<String, Object?> toJson() => {
    'item_ref': itemRef,
    'anchor_server_ms': anchorServerMs,
    'position_ms': positionMs,
    'rate': rate,
    'paused': paused,
  };

  static Playback? _parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final itemRef = _itemRef(m['item_ref']);
    final anchor = _int(m['anchor_server_ms']);
    final position = _int(m['position_ms']);
    final rate = _num(m['rate']);
    final paused = m['paused'];
    if (itemRef == null || anchor == null || position == null || position < 0) return null;
    if (rate == null || rate < 0.25 || rate > 4 || paused is! bool) return null;
    return Playback(
      itemRef: itemRef,
      anchorServerMs: anchor,
      positionMs: position,
      rate: rate,
      paused: paused,
    );
  }
}

class QueueItem {
  const QueueItem({required this.itemRef, this.title, this.durationMs, this.addedBy});

  final String itemRef;
  final String? title;
  final int? durationMs;
  final String? addedBy;

  Map<String, Object?> toJson() => {
    'item_ref': itemRef,
    'title': ?title,
    'duration_ms': ?durationMs,
    'added_by': ?addedBy,
  };

  static QueueItem? _parse(Object? v) {
    final m = _map(v);
    final itemRef = _itemRef(m?['item_ref']);
    if (m == null || itemRef == null) return null;
    final (title, ok1) = _optStr(m, 'title');
    final (addedBy, ok2) = _optStr(m, 'added_by');
    final duration = m['duration_ms'];
    final durationMs = _int(duration);
    if (!ok1 || !ok2) return null;
    if (duration != null && (durationMs == null || durationMs < 0)) return null;
    return QueueItem(itemRef: itemRef, title: title, durationMs: durationMs, addedBy: addedBy);
  }
}

class Member {
  const Member({required this.userId, this.name, this.caps});

  final String userId;
  final String? name;
  final List<String>? caps;

  Map<String, Object?> toJson() => {'user_id': userId, 'name': ?name, 'caps': ?caps};

  static Member? _parse(Object? v) {
    final m = _map(v);
    final userId = _str(m?['user_id']);
    if (m == null || userId == null) return null;
    final (name, okName) = _optStr(m, 'name');
    final caps = m['caps'];
    final capsList = _list(caps, _str);
    if (!okName || (caps != null && capsList == null)) return null;
    return Member(userId: userId, name: name, caps: capsList);
  }
}

class Observed {
  const Observed({
    required this.offsetMs,
    required this.rttMs,
    required this.driftMs,
    required this.source,
  });

  final double offsetMs;
  final double rttMs;
  final double driftMs;
  final String source;

  Map<String, Object?> toJson() => {
    'offset_ms': offsetMs,
    'rtt_ms': rttMs,
    'drift_ms': driftMs,
    'source': source,
  };

  static Observed? _parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final offset = _num(m['offset_ms']);
    final rtt = _num(m['rtt_ms']);
    final drift = _num(m['drift_ms']);
    final source = _str(m['source']);
    if (offset == null || rtt == null || drift == null || source == null) return null;
    return Observed(offsetMs: offset, rttMs: rtt, driftMs: drift, source: source);
  }
}

// ---- the ten message bodies ----

sealed class Body {
  const Body();

  String get type;
  Map<String, Object?> toJson();
}

class HelloMsg extends Body {
  const HelloMsg({
    required this.clientId,
    required this.name,
    required this.ver,
    this.caps = const [],
  });

  final String clientId;
  final String name;
  final String ver;
  final List<String> caps;

  @override
  String get type => 'hello';

  @override
  Map<String, Object?> toJson() => {
    'proto': protocolVersion,
    'client': {'id': clientId, 'name': name, 'ver': ver},
    'caps': caps,
  };

  static HelloMsg? _parse(Map<String, Object?> m) {
    final client = _map(m['client']);
    final id = _str(client?['id']);
    final name = _str(client?['name']);
    final ver = _str(client?['ver']);
    final caps = m['caps'];
    final capsList = _list(caps, _str);
    if (m['proto'] != protocolVersion || id == null || name == null || ver == null) return null;
    if (caps != null && capsList == null) return null;
    return HelloMsg(clientId: id, name: name, ver: ver, caps: capsList ?? const []);
  }
}

class Snapshot {
  const Snapshot({
    required this.rev,
    required this.playback,
    required this.queue,
    required this.presence,
    this.meta,
  });

  final int rev;
  final Playback? playback;
  final List<QueueItem> queue;
  final List<Member> presence;
  final RoomMeta? meta;
}

class RoomMeta {
  const RoomMeta({required this.hostId, required this.hostName, required this.controls, required this.locked});

  final String hostId;
  final String hostName;
  final String controls;
  final bool locked;

  Map<String, Object?> toJson() => {
    'host_id': hostId,
    'host_name': hostName,
    'controls': controls,
    'locked': locked,
  };

  static RoomMeta? parse(Object? value) {
    final m = _map(value);
    if (m == null) return null;
    final hostId = _str(m['host_id']);
    final hostName = _str(m['host_name']);
    final controls = m['controls'];
    final locked = m['locked'];
    if (hostId == null || hostName == null || (controls != 'host' && controls != 'all') || locked is! bool) return null;
    return RoomMeta(hostId: hostId, hostName: hostName, controls: controls as String, locked: locked);
  }
}

class WelcomeMsg extends Body {
  const WelcomeMsg({required this.snapshot, required this.serverNow});

  final Snapshot snapshot;
  final int serverNow;

  @override
  String get type => 'welcome';

  @override
  Map<String, Object?> toJson() => {
    'snapshot': {
      'rev': snapshot.rev,
      'playback': snapshot.playback?.toJson(),
      'queue': [for (final q in snapshot.queue) q.toJson()],
      'presence': [for (final p in snapshot.presence) p.toJson()],
      if (snapshot.meta != null) 'meta': snapshot.meta!.toJson(),
    },
    'server_now': serverNow,
  };

  static WelcomeMsg? _parse(Map<String, Object?> m) {
    final s = _map(m['snapshot']);
    final serverNow = _int(m['server_now']);
    if (s == null || serverNow == null) return null;
    final rev = _int(s['rev']);
    final (playback, okPlayback) = _nullablePlayback(s);
    final queue = _list(s['queue'], QueueItem._parse);
    final presence = _list(s['presence'], Member._parse);
    final meta = s.containsKey('meta') ? RoomMeta.parse(s['meta']) : null;
    if (rev == null || rev < 0 || !okPlayback || queue == null || presence == null || (s.containsKey('meta') && meta == null)) return null;
    return WelcomeMsg(
      snapshot: Snapshot(rev: rev, playback: playback, queue: queue, presence: presence, meta: meta),
      serverNow: serverNow,
    );
  }
}

class ClockPingMsg extends Body {
  const ClockPingMsg({required this.pingId, required this.t0});

  final String pingId;
  final int t0;

  @override
  String get type => 'clock_ping';

  @override
  Map<String, Object?> toJson() => {'ping_id': pingId, 't0': t0};

  static ClockPingMsg? _parse(Map<String, Object?> m) {
    final pingId = _str(m['ping_id']);
    final t0 = _int(m['t0']);
    if (pingId == null || t0 == null) return null;
    return ClockPingMsg(pingId: pingId, t0: t0);
  }
}

class ClockPongMsg extends Body {
  const ClockPongMsg({required this.pingId, required this.t0, required this.t1, required this.t2});

  final String pingId;
  final int t0;

  /// Server receive time.
  final int t1;

  /// Server send time.
  final int t2;

  @override
  String get type => 'clock_pong';

  @override
  Map<String, Object?> toJson() => {'ping_id': pingId, 't0': t0, 't1': t1, 't2': t2};

  static ClockPongMsg? _parse(Map<String, Object?> m) {
    final pingId = _str(m['ping_id']);
    final t0 = _int(m['t0']);
    final t1 = _int(m['t1']);
    final t2 = _int(m['t2']);
    if (pingId == null || t0 == null || t1 == null || t2 == null) return null;
    return ClockPongMsg(pingId: pingId, t0: t0, t1: t1, t2: t2);
  }
}

const List<String> intentOps = ['play', 'pause', 'seek', 'queue_add', 'queue_remove', 'skip', 'set_controls', 'lock', 'kick'];

class IntentMsg extends Body {
  const IntentMsg({required this.op, this.args = const {}});

  final String op;
  final Map<String, Object?> args;

  @override
  String get type => 'intent';

  @override
  Map<String, Object?> toJson() => {'op': op, 'args': args};

  static IntentMsg? _parse(Map<String, Object?> m) {
    final op = _str(m['op']);
    final args = _map(m['args']);
    if (op == null || !intentOps.contains(op) || args == null) return null;
    return IntentMsg(op: op, args: args);
  }
}

class StateMsg extends Body {
  const StateMsg({required this.rev, required this.playback, required this.queue, this.meta});

  final int rev;
  final Playback? playback;
  final List<QueueItem> queue;
  final RoomMeta? meta;

  @override
  String get type => 'state';

  @override
  Map<String, Object?> toJson() => {
    'rev': rev,
    'playback': playback?.toJson(),
    'queue': [for (final q in queue) q.toJson()],
    if (meta != null) 'meta': meta!.toJson(),
  };

  static StateMsg? _parse(Map<String, Object?> m) {
    final rev = _int(m['rev']);
    final (playback, okPlayback) = _nullablePlayback(m);
    final queue = _list(m['queue'], QueueItem._parse);
    final meta = m.containsKey('meta') ? RoomMeta.parse(m['meta']) : null;
    if (rev == null || rev < 0 || !okPlayback || queue == null || (m.containsKey('meta') && meta == null)) return null;
    return StateMsg(rev: rev, playback: playback, queue: queue, meta: meta);
  }
}

class ReportMsg extends Body {
  const ReportMsg({required this.activityId, required this.observed});

  final String? activityId;
  final Observed observed;

  @override
  String get type => 'report';

  @override
  Map<String, Object?> toJson() => {'activity_id': activityId, 'observed': observed.toJson()};

  static ReportMsg? _parse(Map<String, Object?> m) {
    final (activityId, okActivity) = _optStr(m, 'activity_id');
    final observed = Observed._parse(m['observed']);
    if (!okActivity || observed == null) return null;
    return ReportMsg(activityId: activityId, observed: observed);
  }
}

class PresenceMsg extends Body {
  const PresenceMsg({required this.userId, this.name, required this.joined});

  final String userId;
  final String? name;

  /// `action: "join"` when true, `"leave"` when false.
  final bool joined;

  @override
  String get type => 'presence';

  @override
  Map<String, Object?> toJson() => {
    'user_id': userId,
    'name': ?name,
    'action': joined ? 'join' : 'leave',
  };

  static PresenceMsg? _parse(Map<String, Object?> m) {
    final userId = _str(m['user_id']);
    final (name, okName) = _optStr(m, 'name');
    final action = m['action'];
    if (userId == null || !okName || (action != 'join' && action != 'leave')) return null;
    return PresenceMsg(userId: userId, name: name, joined: action == 'join');
  }
}

class EventMsg extends Body {
  const EventMsg({required this.kind, required this.data});

  final String kind;
  final Map<String, Object?> data;

  @override
  String get type => 'event';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'data': data};

  static EventMsg? _parse(Map<String, Object?> m) {
    final kind = _str(m['kind']);
    final data = _map(m['data']);
    if (kind == null || data == null) return null;
    return EventMsg(kind: kind, data: data);
  }
}

class RejectMsg extends Body {
  const RejectMsg({required this.code, required this.message, this.reqId});

  final String code;
  final String message;
  final String? reqId;

  @override
  String get type => 'reject';

  @override
  Map<String, Object?> toJson() => {'code': code, 'message': message, 'req_id': ?reqId};

  static RejectMsg? _parse(Map<String, Object?> m) {
    final code = _str(m['code']);
    final message = _str(m['message']);
    final (reqId, okReq) = _optStr(m, 'req_id');
    if (code == null || message == null || !okReq) return null;
    return RejectMsg(code: code, message: message, reqId: reqId);
  }
}

// ---- JSON helpers: return null instead of throwing ----

Map<String, Object?>? _map(Object? v) => v is Map<String, Object?> ? v : null;

String? _str(Object? v) => v is String ? v : null;

String? _itemRef(Object? v) => v is String && isItemRef(v) ? v : null;

/// JSON Schema `integer`: an int, or a float with no fractional part.
int? _int(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  return null;
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// A list whose every element parses; null if any does not.
List<T>? _list<T>(Object? v, T? Function(Object?) parse) {
  if (v is! List) return null;
  final out = <T>[];
  for (final e in v) {
    final x = parse(e);
    if (x == null) return null;
    out.add(x);
  }
  return out;
}

/// An optional (or null) string field: `(value, ok)`; ok is false if present with another type.
(String?, bool) _optStr(Map<String, Object?> m, String key) {
  final v = m[key];
  return v == null ? (null, true) : (_str(v), v is String);
}

/// The required `playback` key: an anchor or null. ok is false if missing or malformed.
(Playback?, bool) _nullablePlayback(Map<String, Object?> m) {
  if (!m.containsKey('playback')) return (null, false);
  final v = m['playback'];
  if (v == null) return (null, true);
  final pb = Playback._parse(v);
  return (pb, pb != null);
}
