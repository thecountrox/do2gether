import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/links.dart';

void main() {
  final token =
      '${base64Url.encode(utf8.encode(jsonEncode({'room': 'abc123', 'exp': 123456789}))).replaceAll('=', '')}.signature';

  test('custom scheme invite', () {
    expect(parseInviteLink('watchtogether://join?room=abc123&token=$token'), (
      room: 'abc123',
      token: token,
    ));
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
      'watchtogether://join?room=abc123',
      'ftp://example.com/join/$token',
    ]) {
      expect(parseInviteLink(value), isNull, reason: value);
    }
  });
}
