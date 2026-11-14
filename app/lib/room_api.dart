/// The HTTP calls Home makes around joining: health/RTT, room lookup, room creation.
library;

import 'dart:convert';
import 'dart:io';

import 'room_client.dart';

typedef CreatedRoom = ({String room, String token, String hostId});

/// What `GET /rooms/{id}` says about a room. Accepts both servers' shapes: the TypeScript one
/// (`host_name`, `member_count`) and the Rust one (`host_name`, `members[]`).
class RoomInfo {
  const RoomInfo({
    required this.roomId,
    this.hostName,
    this.memberCount = 0,
    this.memberNames = const [],
    this.itemRef,
    this.positionMs,
    this.paused,
  });
  final String roomId;
  final String? hostName;
  final int memberCount;
  final List<String> memberNames;
  final String? itemRef;
  final int? positionMs;
  final bool? paused;
}

RoomInfo? parseRoomInfo(Object? json) {
  if (json is! Map<String, Object?>) return null;
  final id = json['room_id'];
  if (id is! String) return null;
  final names = <String>[
    if (json['members'] case final List<Object?> members)
      for (final m in members)
        if (m case {'name': final String name} when name.isNotEmpty) name,
  ];
  final host = json['host_name'];
  final playback = json['playback'];
  return RoomInfo(
    roomId: id,
    hostName: host is String && host.isNotEmpty ? host : null,
    memberCount: switch (json['member_count']) {
      final int n => n,
      _ => (json['members'] as List<Object?>?)?.length ?? names.length,
    },
    memberNames: names,
    itemRef: playback is Map<String, Object?> ? playback['item_ref'] as String? : null,
    positionMs: playback is Map<String, Object?>
        ? (playback['position_ms'] as num?)?.toInt()
        : null,
    paused: playback is Map<String, Object?> ? playback['paused'] as bool? : null,
  );
}

/// The `exp` (server epoch ms) inside a `base64url(json).sig` join token, if it has one.
int? tokenExpiryMs(String token) {
  final parts = token.split('.');
  if (parts.length != 2) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
    );
    if (payload case {'exp': final int exp}) return exp;
  } on Object {
    return null;
  }
  return null;
}

abstract interface class RoomApi {
  /// Round trip of `GET /health` in ms; throws when the server is unreachable.
  Future<int> ping(Uri server);

  /// The room, or null when the server says it does not exist (404). Throws on any other failure.
  Future<RoomInfo?> lookup(Uri server, String room);

  Future<CreatedRoom> create(Uri server);
}

class HttpRoomApi implements RoomApi {
  const HttpRoomApi();

  static Uri _endpoint(Uri server, String path) {
    final rooms = roomsUri(server);
    final base = rooms.path.substring(0, rooms.path.length - '/rooms'.length);
    return rooms.replace(path: '$base$path');
  }

  Future<(int, String)> _request(String method, Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, uri);
      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      return (response.statusCode, body);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<int> ping(Uri server) async {
    final watch = Stopwatch()..start();
    final (status, _) = await _request('GET', _endpoint(server, '/health'));
    if (status != HttpStatus.ok) throw HttpException('HTTP $status');
    return watch.elapsedMilliseconds;
  }

  @override
  Future<RoomInfo?> lookup(Uri server, String room) async {
    final (status, body) = await _request(
      'GET',
      _endpoint(server, '/rooms/${Uri.encodeComponent(room)}'),
    );
    if (status == HttpStatus.notFound) return null;
    if (status != HttpStatus.ok) throw HttpException('HTTP $status');
    return parseRoomInfo(jsonDecode(body)) ??
        (throw const FormatException('unexpected response from GET /rooms/{id}'));
  }

  @override
  Future<CreatedRoom> create(Uri server) async {
    final (status, body) = await _request('POST', roomsUri(server));
    if (status != HttpStatus.created && status != HttpStatus.ok) {
      throw HttpException('HTTP $status');
    }
    if (jsonDecode(body) case {
      'room_id': final String room,
      'join_token': final String token,
      'host_id': final String hostId,
    }) {
      return (room: room, token: token, hostId: hostId);
    }
    throw const FormatException('unexpected response from POST /rooms');
  }
}
