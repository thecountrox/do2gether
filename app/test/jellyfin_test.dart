import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/jellyfin.dart';
import 'package:watch_together/local_copy.dart';

import 'support.dart';

void main() {
  group('parseJellyfinRef', () {
    test('splits host and item id', () {
      expect(parseJellyfinRef('jellyfin:jelly.example/$jellyItemId'), (
        host: 'jelly.example',
        itemId: jellyItemId,
      ));
      expect(parseJellyfinRef('jellyfin:192.168.1.20:8096/$jellyItemId'), (
        host: '192.168.1.20:8096',
        itemId: jellyItemId,
      ));
    });

    test('rejects anything else', () {
      for (final bad in [
        '',
        'jellyfin:',
        'jellyfin:jelly.example/',
        'jellyfin:jelly.example/${jellyItemId.toUpperCase()}',
        'jellyfin:jelly.example/${jellyItemId.substring(1)}',
        'jellyfin:jelly.example/${jellyItemId}0',
        'jellyfin:jelly.example:123456/$jellyItemId',
        'jellyfin:jelly.example/x/$jellyItemId',
        'jellyfin:jelly example/$jellyItemId',
        'jellyfin://jelly.example/$jellyItemId',
        'url:https://jelly.example/$jellyItemId',
        hostRef,
      ]) {
        expect(parseJellyfinRef(bad), isNull, reason: bad);
      }
    });
  });

  test('jellyfinRef keeps the port only when the URL has one', () {
    expect(
      jellyfinRef(Uri.parse('https://jelly.example'), jellyItemId),
      'jellyfin:jelly.example/$jellyItemId',
    );
    expect(
      jellyfinRef(Uri.parse('http://192.168.1.20:8096/'), jellyItemId),
      'jellyfin:192.168.1.20:8096/$jellyItemId',
    );
    expect(
      parseJellyfinRef(
        jellyfinRef(Uri.parse('https://jelly.example'), jellyItemId),
      ),
      isNotNull,
    );
  });

  test('streamUrl is direct play with the token as api_key', () {
    const want =
        'https://jelly.example/Videos/$jellyItemId/stream?static=true&api_key=abc123';
    expect(
      streamUrl(
        server: 'https://jelly.example',
        token: 'abc123',
        itemId: jellyItemId,
      ),
      want,
    );
    expect(
      streamUrl(
        server: 'https://jelly.example/',
        token: 'abc123',
        itemId: jellyItemId,
      ),
      want,
    );
    expect(
      streamUrl(
        server: 'http://nas:8096/jf',
        token: 'a b',
        itemId: jellyItemId,
      ),
      'http://nas:8096/jf/Videos/$jellyItemId/stream?static=true&api_key=a+b',
    );
  });

  test('validateJellyfinServer wants a reachable http(s) host', () {
    expect(validateJellyfinServer('https://jelly.example'), isNull);
    expect(validateJellyfinServer(' http://192.168.1.20:8096 '), isNull);
    expect(validateJellyfinServer(''), isNotNull);
    expect(validateJellyfinServer('jelly.example'), isNotNull);
    expect(validateJellyfinServer('ftp://jelly.example'), isNotNull);
    expect(validateJellyfinServer('http://[::1]:8096'), isNotNull);
  });

  test('ticks are 100 ns', () {
    expect(ticksToDuration(200000000), const Duration(seconds: 20));
    expect(ticksToDuration(0), Duration.zero);
  });

  test('parseItems maps Id, Name and RunTimeTicks and skips junk', () {
    final items = parseItems({
      'Items': [
        {'Id': jellyItemId, 'Name': 'sample-room', 'RunTimeTicks': 200000000},
        {'Id': 'aaaabbbbccccddddeeeeffff00001111', 'Name': 'No runtime'},
        {'Id': 'not-an-id', 'Name': 'Bad id'},
        {'Name': 'No id'},
        'junk',
      ],
      'TotalRecordCount': 5,
    });
    expect(items.map((i) => i.name), ['sample-room', 'No runtime']);
    expect(items.first.id, jellyItemId);
    expect(items.first.runtime, const Duration(seconds: 20));
    expect(items.last.runtime, isNull);
    expect(parseItems({'Items': 'nope'}), isEmpty);
    expect(parseItems(null), isEmpty);
  });

  test('the Authorization header carries the token when there is one', () {
    final anon = jellyfinAuthorization();
    expect(
      anon,
      startsWith(
        'MediaBrowser Client="do2gether", Device="desktop", DeviceId="',
      ),
    );
    expect(anon, endsWith('Version="0.1.0"'));
    expect(anon, isNot(contains('Token=')));
    expect(jellyfinAuthorization(token: 't0k'), endsWith(', Token="t0k"'));
    expect(jellyfinDeviceId('box'), jellyfinDeviceId('box'));
    expect(jellyfinDeviceId('box'), hasLength(32));
    expect(jellyfinDeviceId('box'), isNot(jellyfinDeviceId('other')));
  });

  group('config', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wt_jellyfin_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round-trips through a file it creates', () async {
      final path = '${dir.path}/nested/do2gether/jellyfin.json';
      const config = (
        server: 'https://jelly.example',
        token: 'fake',
        user: 'mika',
      );
      await saveJellyfinConfig(path, config);
      expect(await loadJellyfinConfig(path), config);
      if (!Platform.isWindows) {
        expect(File(path).statSync().mode & 0x1ff, 0x180); // 0600
      }
    });

    test('missing or garbled files load as null', () async {
      expect(await loadJellyfinConfig('${dir.path}/absent.json'), isNull);
      final garbage = File('${dir.path}/garbage.json')
        ..writeAsStringSync('{nope');
      expect(await loadJellyfinConfig(garbage.path), isNull);
      final partial = File('${dir.path}/partial.json')
        ..writeAsStringSync('{"server":"https://jelly.example"}');
      expect(await loadJellyfinConfig(partial.path), isNull);
    });

    test('HttpJellyfinApi.restore reads the saved session', () async {
      final path = '${dir.path}/jellyfin.json';
      final api = HttpJellyfinApi(configPath: path);
      expect(await api.restore(), isNull);
      await saveJellyfinConfig(path, (
        server: 'https://jelly.example',
        token: 'fake',
        user: 'mika',
      ));
      final session = await api.restore();
      expect(session?.server, Uri.parse('https://jelly.example'));
      expect(session?.token, 'fake');
      expect(session?.user, 'mika');
    });

    test('lives under ~/.config, or %APPDATA% on Windows', () {
      expect(
        jellyfinConfigPath(environment: {'HOME': '/home/mika'}, windows: false),
        '/home/mika/.config/do2gether/jellyfin.json',
      );
      expect(
        jellyfinConfigPath(
          environment: {'APPDATA': r'C:\Users\mika\AppData\Roaming'},
          windows: true,
        ),
        r'C:\Users\mika\AppData\Roaming\do2gether\jellyfin.json',
      );
    });
  });

  test('a remote copy shows Jellyfin and its runtime, not bytes', () {
    const copy = LocalCopy.remote(
      url: 'https://jelly.example/Videos/x/stream',
      itemRef: 'jellyfin:jelly.example/$jellyItemId',
      title: 'sample-room',
      duration: Duration(seconds: 20),
    );
    expect(copy.isRemote, isTrue);
    expect(copy.name, 'sample-room');
    expect(copy.details, 'Jellyfin · 0:20');
    expect(hostCopy.isRemote, isFalse);
    expect(hostCopy.name, 'movie-night_1080p.mkv');
  });
}
