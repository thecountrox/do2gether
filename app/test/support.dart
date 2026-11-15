import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/jellyfin.dart';
import 'package:watch_together/local_copy.dart';
import 'package:watch_together/room_api.dart';

const String roomCode = 'k3f9x2qa';
const String hostRef =
    'file:sha256p:1400000000:0123456789abcdef0123456789abcdef:fedcba9876543210fedcba9876543210';

/// A `base64url(json).sig` join token; [exp] is epoch ms.
String token(String room, {int exp = 123456789}) =>
    '${base64Url.encode(utf8.encode(jsonEncode({'room': room, 'exp': exp}))).replaceAll('=', '')}.signature';

int inTenMinutes() => DateTime.now().millisecondsSinceEpoch + 600000;

const LocalCopy hostCopy = LocalCopy(
  path: '/videos/movie-night_1080p.mkv',
  bytes: 1400000000,
  itemRef: hostRef,
  duration: Duration(minutes: 112, seconds: 10),
);

class FakeRoomApi implements RoomApi {
  FakeRoomApi({this.info, this.fail = false});

  RoomInfo? info;
  bool fail;
  int lookups = 0;

  @override
  Future<int> ping(Uri server) async => 42;

  @override
  Future<RoomInfo?> lookup(Uri server, String room) async {
    lookups++;
    if (fail) throw const HttpException('down');
    return info;
  }

  @override
  Future<CreatedRoom> create(Uri server) async => (
    room: roomCode,
    token: token(roomCode, exp: inTenMinutes()),
    hostId: 'host-1',
  );
}

const String jellyItemId = '8b2ab2fa2506721d49db38751b5142c9';

const List<JellyfinItem> jellyMovies = [
  JellyfinItem(id: 'aaaabbbbccccddddeeeeffff00001111', name: 'Big Buck Bunny'),
  JellyfinItem(
    id: jellyItemId,
    name: 'sample-room',
    runtime: Duration(seconds: 20),
  ),
];

/// Answers from memory; never touches the network.
class FakeJellyfinSession extends JellyfinSession {
  FakeJellyfinSession({required super.server, required super.user, this.fail})
    : super(token: 'fake-token');

  final Object? fail;

  @override
  Future<List<JellyfinItem>> movies() async {
    if (fail case final e?) throw e;
    return jellyMovies;
  }
}

class FakeJellyfinApi implements JellyfinApi {
  FakeJellyfinApi({this.saved, this.error});

  JellyfinSession? saved;
  Object? error;
  final List<({Uri server, String user, String pass})> connects = [];

  @override
  Future<JellyfinSession?> restore() async => saved;

  @override
  Future<JellyfinSession> connect({
    required Uri server,
    required String user,
    required String pass,
  }) async {
    connects.add((server: server, user: user, pass: pass));
    if (error case final e?) throw e;
    return FakeJellyfinSession(server: server, user: user);
  }
}

/// Desktop window at 1:1 pixels; restored after the test.
void useWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

const List<Size> desktopSizes = [Size(1440, 900), Size(1100, 720)];

/// Hyprland tiles the window to this on a 1920 screen, ignoring the min-size hint.
const Size tiledSize = Size(856, 1038);

/// An in-memory clipboard behind `SystemChannels.platform`.
class FakeClipboard {
  String? text;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return {'text': text};
            case 'Clipboard.hasStrings':
              return {'value': text != null};
          }
          return null;
        });
  }
}
