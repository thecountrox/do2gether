/// Client view of server time: four-timestamp pings, median offset over a burst of samples.
///
/// Local time is a monotonic stopwatch anchored to the wall clock once at construction, so wall
/// clock steps (NTP) never move [Clock.serverNow]; only a completed burst does.
library;

const int samplesPerBurst = 10;

/// One ping: `offset = ((t1 - t0) + (t2 - t3)) / 2`, `rtt = (t3 - t0) - (t2 - t1)`.
typedef ClockSample = ({double offsetMs, double rttMs});

ClockSample clockSample(double t0, double t1, double t2, double t3) =>
    (offsetMs: ((t1 - t0) + (t2 - t3)) / 2, rttMs: (t3 - t0) - (t2 - t1));

/// The middle value (mean of the two middle values for an even count); 0 for no values.
/// A minority of outliers, however large, cannot move it.
double median(Iterable<double> values) {
  final xs = values.toList()..sort();
  final n = xs.length;
  if (n == 0) return 0;
  return n.isOdd ? xs[n ~/ 2] : (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
}

class Clock {
  Clock() : _originMs = DateTime.now().microsecondsSinceEpoch / 1000;

  final double _originMs;
  final Stopwatch _watch = Stopwatch()..start();
  final List<ClockSample> _burst = [];
  double _offsetMs = 0;
  double _rttMs = 0;
  bool _ready = false;

  /// `server - local` from the last complete burst; 0 (trust the wall clock) until then.
  double get offsetMs => _offsetMs;
  double get rttMs => _rttMs;

  /// True once the first burst has completed.
  bool get ready => _ready;

  double localMs() => _originMs + _watch.elapsedMicroseconds / 1000;

  int serverNow() => (localMs() + _offsetMs).round();

  /// Adds one sample to the current burst. Returns true when the burst is complete; the median
  /// offset and median RTT then replace the previous estimate.
  bool ingest(double t0, double t1, double t2, double t3) {
    _burst.add(clockSample(t0, t1, t2, t3));
    if (_burst.length < samplesPerBurst) return false;
    _offsetMs = median(_burst.map((s) => s.offsetMs));
    _rttMs = median(_burst.map((s) => s.rttMs));
    _burst.clear();
    _ready = true;
    return true;
  }

  /// Drops a partial burst; a refresh starts again from zero samples.
  void restartBurst() => _burst.clear();
}
