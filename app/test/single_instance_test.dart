import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/single_instance.dart';

void main() {
  test('the first instance claims, the second forwards, and the payload arrives', () async {
    final port = 45900 + (DateTime.now().microsecond % 40);
    final first = SingleInstance(port: port);
    final second = SingleInstance(port: port);

    expect(await first.claim(), isTrue, reason: 'first instance should own the port');
    addTearDown(() async {
      await first.close();
      await second.close();
    });

    final received = Completer<String>();
    first.invites.listen((value) {
      if (!received.isCompleted) received.complete(value);
    });

    expect(await first.claim(), isFalse, reason: 'a second bind on the same port must fail');

    const invite = 'do2gether://join?room=abc123&token=abc.sig';
    expect(await second.forward(invite), isTrue);
    expect(await received.future.timeout(const Duration(seconds: 3)), invite);
  });

  test('forwarding with nobody listening reports failure', () async {
    final port = 45950 + (DateTime.now().microsecond % 40);
    final lonely = SingleInstance(port: port);
    expect(await lonely.forward('do2gether://join?room=a&token=b.c'), isFalse);
    await lonely.close();
  });

  test('an empty payload is not forwarded as an invite', () async {
    final port = 45995 % 65535;
    final owner = SingleInstance(port: port == 0 ? 45999 : port);
    if (!await owner.claim()) {
      await owner.close();
      return; // port busy in this environment; nothing to assert
    }
    addTearDown(owner.close);
    var seen = 0;
    owner.invites.listen((_) => seen++);
    final other = SingleInstance(port: port == 0 ? 45999 : port);
    expect(await other.forward(null), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(seen, 0);
  });
}
