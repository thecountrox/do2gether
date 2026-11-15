import 'dart:convert';

typedef InviteLink = ({String room, String token});

/// Schemes the desktop app registers with the OS for invite links.
const Set<String> inviteSchemes = {'do2gether', 'watchtogether'};

/// Extracts a room and token from an invite or a manual room/token pair.
InviteLink? parseInviteLink(String input) {
  final value = input.trim();
  final uri = Uri.tryParse(value);
  if (uri != null &&
      uri.hasScheme &&
      value.contains('://') &&
      !inviteSchemes.contains(uri.scheme) &&
      uri.scheme != 'https') {
    return null;
  }
  if (uri != null && inviteSchemes.contains(uri.scheme) && uri.host == 'join') {
    final room = uri.queryParameters['room'];
    final token = uri.queryParameters['token'];
    if (room != null &&
        room.isNotEmpty &&
        token != null &&
        token.isNotEmpty &&
        !room.contains('/') &&
        !token.contains('/')) {
      return (room: room, token: token);
    }
    return null;
  }
  if (uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments.first == 'join') {
    final token = uri.pathSegments.last;
    try {
      final parts = token.split('.');
      if (parts.length != 2 || parts[1].isEmpty) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
      );
      if (payload case {'room': String room, 'exp': int exp}
          when room.isNotEmpty && exp > 0) {
        return (room: room, token: token);
      }
    } on Object {
      return null;
    }
    return null;
  }
  final match = RegExp(r'^([^\s:]+)(?:\s+|:)([^\s:]+)$').firstMatch(value);
  if (match == null ||
      match[1]!.contains('/') ||
      match[2]!.contains('/') ||
      match[1]!.contains('?') ||
      match[2]!.contains('?')) {
    return null;
  }
  return (room: match[1]!, token: match[2]!);
}

String inviteUrl(Uri server, String token) => server
    .replace(
      path: '${server.path.replaceFirst(RegExp(r'/+$'), '')}/join/$token',
      query: null,
      fragment: null,
    )
    .toString();
