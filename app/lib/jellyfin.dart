/// Jellyfin as a media source. The room carries only `jellyfin:<host>/<itemId>`; every client
/// streams the item from its own Jellyfin with its own token. The room server never sees media.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'protocol.dart';

const String jellyfinClient = 'do2gether';
const String jellyfinVersion = '0.1.0';

final RegExp _refParts = RegExp(
  r'^jellyfin:([A-Za-z0-9.-]+(?::[0-9]{1,5})?)/([0-9a-f]{32})$',
);
final RegExp _itemId = RegExp(r'^[0-9a-f]{32}$');

/// `jellyfin:<host>[:<port>]/<32 lowercase hex itemId>` split into its parts; null otherwise.
({String host, String itemId})? parseJellyfinRef(String ref) {
  final m = _refParts.firstMatch(ref);
  if (m == null || !isItemRef(ref)) return null;
  return (host: m[1]!, itemId: m[2]!);
}

/// The ref for [itemId] on [server]: its host, plus the port only when the URL spells one out.
String jellyfinRef(Uri server, String itemId) =>
    'jellyfin:${server.hasPort ? '${server.host}:${server.port}' : server.host}/$itemId';

/// Direct play, no transcoding: `{server}/Videos/{itemId}/stream?static=true&api_key={token}`.
String streamUrl({
  required String server,
  required String token,
  required String itemId,
}) =>
    '${server.replaceFirst(RegExp(r'/+$'), '')}/Videos/$itemId/stream'
    '?static=true&api_key=${Uri.encodeQueryComponent(token)}';

String? validateJellyfinServer(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return 'Enter an http:// or https:// server URL';
  }
  if (!isItemRef(jellyfinRef(uri, '0' * 32))) {
    return 'Use a host name or IPv4 address everyone in the room can reach';
  }
  return null;
}

/// Jellyfin counts runtime in 100 ns ticks.
Duration ticksToDuration(int ticks) => Duration(microseconds: ticks ~/ 10);

/// Same id on every run, so signing in again replaces this machine's Jellyfin session.
String jellyfinDeviceId([String? hostname]) => sha256
    .convert(utf8.encode('do2gether:${hostname ?? Platform.localHostname}'))
    .toString()
    .substring(0, 32);

/// The `MediaBrowser` header. This server answers 401 to `X-Emby-Token` and to `?api_key=` on
/// `/Items`; the token has to ride in here.
String jellyfinAuthorization({String? token}) =>
    'MediaBrowser Client="$jellyfinClient", Device="desktop", '
    'DeviceId="${jellyfinDeviceId()}", Version="$jellyfinVersion"'
    '${token == null ? '' : ', Token="$token"'}';

/// A failed Jellyfin call, carrying the server's own words.
class JellyfinException implements Exception {
  const JellyfinException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

class JellyfinItem {
  const JellyfinItem({required this.id, required this.name, this.runtime});
  final String id;
  final String name;
  final Duration? runtime;
}

/// `GET /Items` → movies with a usable id. Items without `RunTimeTicks` get no runtime.
List<JellyfinItem> parseItems(Object? json) {
  final items = switch (json) {
    {'Items': final List<Object?> items} => items,
    _ => const <Object?>[],
  };
  return [
    for (final item in items)
      if (item case final Map<String, Object?> m)
        if (m case {'Id': final String id, 'Name': final String name}
            when _itemId.hasMatch(id))
          JellyfinItem(
            id: id,
            name: name,
            runtime: switch (m['RunTimeTicks']) {
              final int ticks when ticks > 0 => ticksToDuration(ticks),
              _ => null,
            },
          ),
  ];
}

/// A signed-in user on one Jellyfin server.
class JellyfinSession {
  const JellyfinSession({
    required this.server,
    required this.token,
    required this.user,
  });
  final Uri server;
  final String token;
  final String user;

  Future<List<JellyfinItem>> movies() async {
    final (status, body) = await _send(
      'GET',
      _endpoint(server, '/Items', const {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie',
        'Limit': '100',
        'SortBy': 'SortName',
      }),
      auth: jellyfinAuthorization(token: token),
    );
    if (status != HttpStatus.ok) throw _failure(status, body);
    return parseItems(_decode(body));
  }
}

Future<JellyfinSession> signIn({
  required Uri server,
  required String user,
  required String pass,
}) async {
  final (status, body) = await _send(
    'POST',
    _endpoint(server, '/Users/AuthenticateByName'),
    auth: jellyfinAuthorization(),
    json: {'Username': user, 'Pw': pass},
  );
  if (status != HttpStatus.ok) throw _failure(status, body);
  if (_decode(body) case {'AccessToken': final String token}
      when token.isNotEmpty) {
    return JellyfinSession(server: server, token: token, user: user);
  }
  throw const JellyfinException('Jellyfin signed in but sent no access token');
}

typedef JellyfinConfig = ({String server, String token, String user});

/// `~/.config/do2gether/jellyfin.json`, or `%APPDATA%\do2gether\jellyfin.json` on Windows.
String jellyfinConfigPath({Map<String, String>? environment, bool? windows}) {
  final env = environment ?? Platform.environment;
  return (windows ?? Platform.isWindows)
      ? '${env['APPDATA'] ?? ''}\\do2gether\\jellyfin.json'
      : '${env['HOME'] ?? ''}/.config/do2gether/jellyfin.json';
}

/// The saved sign-in, or null when there is none or it does not parse.
Future<JellyfinConfig?> loadJellyfinConfig(String path) async {
  try {
    final json = jsonDecode(await File(path).readAsString());
    if (json case {
      'server': final String server,
      'token': final String token,
      'user': final String user,
    }) {
      return (server: server, token: token, user: user);
    }
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  return null;
}

/// Writes the sign-in, readable by this user only where the OS has modes.
Future<void> saveJellyfinConfig(String path, JellyfinConfig config) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'server': config.server,
      'token': config.token,
      'user': config.user,
    }),
  );
  if (!Platform.isWindows) await Process.run('chmod', ['600', path]);
}

/// Sign-in plus the saved config, behind one seam so Home can be tested offline.
abstract interface class JellyfinApi {
  /// The session saved on this machine, or null when nobody has signed in.
  Future<JellyfinSession?> restore();

  /// Signs in and saves the session for next time.
  Future<JellyfinSession> connect({
    required Uri server,
    required String user,
    required String pass,
  });
}

class HttpJellyfinApi implements JellyfinApi {
  const HttpJellyfinApi({this.configPath});

  /// Overrides [jellyfinConfigPath].
  final String? configPath;

  String get _path => configPath ?? jellyfinConfigPath();

  @override
  Future<JellyfinSession?> restore() async {
    final config = await loadJellyfinConfig(_path);
    final server = config == null ? null : Uri.tryParse(config.server);
    if (config == null || server == null) return null;
    return JellyfinSession(
      server: server,
      token: config.token,
      user: config.user,
    );
  }

  @override
  Future<JellyfinSession> connect({
    required Uri server,
    required String user,
    required String pass,
  }) async {
    final session = await signIn(server: server, user: user, pass: pass);
    try {
      await saveJellyfinConfig(_path, (
        server: '$server',
        token: session.token,
        user: user,
      ));
    } on FileSystemException catch (e) {
      // The session still works for this run; it just will not be remembered.
      stderr.writeln('jellyfin: sign-in not saved: ${e.message}');
    }
    return session;
  }
}

Uri _endpoint(Uri server, String path, [Map<String, String>? query]) =>
    server.replace(
      path: '${server.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      queryParameters: query,
    );

Future<(int, String)> _send(
  String method,
  Uri uri, {
  required String auth,
  Object? json,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.openUrl(method, uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, auth)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    return (response.statusCode, body);
  } on IOException catch (e) {
    final detail = switch (e) {
      SocketException(:final osError?) => osError.message,
      SocketException(:final message) => message,
      TlsException(:final message) => message,
      HttpException(:final message) => message,
      _ => '$e',
    };
    throw JellyfinException("Couldn't reach ${uri.host}: $detail");
  } on TimeoutException {
    throw JellyfinException('${uri.host} took too long to answer');
  } finally {
    client.close(force: true);
  }
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw const JellyfinException('Jellyfin sent something that is not JSON');
  }
}

/// What the server said: a JSON `Message`/`title`/`detail` if it sent one, else its text.
JellyfinException _failure(int status, String body) {
  var text = body.trim();
  try {
    if (jsonDecode(text) case final Map<String, Object?> json) {
      for (final key in const ['Message', 'message', 'title', 'detail']) {
        if (json[key] case final String m when m.isNotEmpty) {
          text = m;
          break;
        }
      }
    }
  } on FormatException {
    // Plain text, which is what this server sends for a wrong password.
  }
  if (text.length > 300) text = '${text.substring(0, 300)}…';
  return JellyfinException(
    text.isEmpty ? 'Jellyfin sent no message' : text,
    status: status,
  );
}
