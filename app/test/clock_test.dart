import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/clock.dart';

/// A ping/pong against a server [offset] ms ahead, [up]/[down] ms each way, 1 ms processing.
List<double> ping(double t0, double offset, double up, double down) {
  final t1 = t0 + up + offset;
  final t2 = t1 + 1;
  final t3 = t2 - offset + down;
  return [t0, t1, t2, t3];
}

bool ingest(Clock c, List<double> s) => c.ingest(s[0], s[1], s[2], s[3]);

void main() {
  test('four-timestamp sample', () {
    // Server 100 ms ahead, 10 ms each way, 2 ms processing.
    final s = clockSample(0, 110, 112, 22);
    expect(s.offsetMs, 100);
    expect(s.rttMs, 20);
  });

  test('median', () {
    expect(median([3, 1, 2]), 2);
    expect(median([4, 1, 3, 2]), 2.5);
    expect(median([]), 0);
  });

  test('a burst of synthetic samples gives the median offset and rtt', () {
    final c = Clock();
    expect(c.ready, isFalse);
    expect(c.offsetMs, 0);
    // Server 250 ms ahead; symmetric paths with jitter between 5 and 14 ms each way.
    for (var i = 0; i < samplesPerBurst; i++) {
      final leg = 5.0 + i;
      final done = ingest(c, ping(1000.0 * i, 250, leg, leg));
      expect(done, i == samplesPerBurst - 1);
    }
    expect(c.ready, isTrue);
    expect(c.offsetMs, 250);
    // rtt = up + down = 2 * (5 + i): median of 10, 12, …, 28.
    expect(c.rttMs, 19);
    expect((c.serverNow() - (c.localMs() + 250)).abs(), lessThanOrEqualTo(1));
  });

  test('outliers do not move the estimate', () {
    final c = Clock();
    for (var i = 0; i < samplesPerBurst; i++) {
      final s = switch (i) {
        // A 5 s stall on the way up, a 3 s stall on the way down, and a wild server timestamp.
        2 => ping(0, 50, 5000, 2),
        5 => ping(0, 50, 2, 3000),
        7 => [0.0, 900000.0, 900001.0, 5.0],
        _ => ping(0, 50, 2, 2),
      };
      ingest(c, s);
    }
    expect(c.offsetMs, 50);
    expect(c.rttMs, 4);
  });

  test('a refresh drops the partial burst and keeps the last estimate', () {
    final c = Clock();
    for (var i = 0; i < samplesPerBurst; i++) {
      ingest(c, ping(0, 50, 2, 2));
    }
    for (var i = 0; i < samplesPerBurst - 1; i++) {
      expect(ingest(c, ping(0, -400, 2, 2)), isFalse);
    }
    expect(c.offsetMs, 50, reason: 'partial burst does not apply');
    c.restartBurst();
    expect(ingest(c, ping(0, -400, 2, 2)), isFalse, reason: 'burst restarted from zero');
    for (var i = 0; i < samplesPerBurst - 1; i++) {
      ingest(c, ping(0, -400, 2, 2));
    }
    expect(c.offsetMs, -400);
  });
}
