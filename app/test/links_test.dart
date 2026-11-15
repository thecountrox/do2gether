import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/links.dart';
import 'package:watch_together/main.dart';

void main() {
  final token =
      '${base64Url.encode(utf8.encode(jsonEncode({'room': 'abc123', 'exp': 123456789}))).replaceAll('=', '')}.signature';

  test('custom scheme invites, both names', () {
    for (final scheme in ['do2gether', 'watchtogether']) {
      expect(parseInviteLink('$scheme://join?room=abc123&token=$token'), (
        room: 'abc123',
        token: token,
      ), reason: scheme);
    }
  });
  test('HTTPS invite decodes room from token', () {
    expect(parseInviteLink('https://example.com/join/$token'), (
      room: 'abc123',
      token: token,
    ));
  });
  test('manual room and token pairs', () {
    expect(parseInviteLink('abc123 $token'), (room: 'abc123', token: token));
    expect(parseInviteLink('abc123:$token'), (room: 'abc123', token: token));
  });
  test('garbage is not an invite', () {
    for (final value in [
      '',
      'garbage',
      'https://example.com/join/garbage',
      'do2gether://join?room=abc123',
      'watchtogether://join?room=abc123',
      'ftp://example.com/join/$token',
    ]) {
      expect(parseInviteLink(value), isNull, reason: value);
    }
  });

  group('inviteFromArgs', () {
    test('picks the invite out of an argv list', () {
      expect(
        inviteFromArgs(['--ozone-platform=wayland', 'do2gether://join?room=abc123&token=$token']),
        'do2gether://join?room=abc123&token=$token',
      );
    });
    test('ignores flags and junk', () {
      expect(inviteFromArgs(['--flag', 'nonsense']), isNull);
      expect(inviteFromArgs(const []), isNull);
    });
    test('accepts a bare https join link', () {
      expect(
        inviteFromArgs(['https://watch.example.com/join/$token']),
        'https://watch.example.com/join/$token',
      );
    });
  });
}
