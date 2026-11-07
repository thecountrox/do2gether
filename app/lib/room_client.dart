/// One WebSocket connection to a room: hello/welcome, clock bursts, outbound envelopes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock.dart';
import 'protocol.dart';

const String clientVersion = '1.0.0';
const Duration clockRefreshEvery = Duration(seconds: 30);

enum ConnectionStatus { connecting, handshaking, joined, closed }

/// `<server path>/rooms` on the same scheme, host and port.
Uri roomsUri(Uri server) =>
    Uri(scheme: server.scheme, host: server.host, port: _port(server), path: '${_base(server)}/rooms');

/// `ws(s)://<host>/<path>/ws?room=…&token=…`; `https` maps to `wss`, anything else to `ws`.
Uri wsUri(Uri server, String room, String token) => Uri(
  scheme: server.scheme == 'https' ? 'wss' : 'ws',
  host: server.host,
  port: _port(server),
  path: '${_base(server)}/ws',
  queryParameters: {'room': room, 'token': token},
);

String _base(Uri server) => server.path.replaceFirst(RegExp(r'/+$'), '');

int? _port(Uri server) => server.hasPort ? server.port : null;

class RoomClient {
  RoomClient({
    required this.server,
    required this.room,
    required this.token,
    required this.name,
    required this.onMessage,
    required this.onChange,
    String? clientId,
  }) : clientId = clientId ?? 'flutter-${_randomHex(6)}';

  final Uri server;
  final String room;
  final String token;
  final String name;

  /// Our `from` and `client.id`. Fresh per connection.
  final String clientId;
  final Clock clock = Clock();

  /// Every valid inbound message except `clock_pong`, which the client consumes itself.
  final void Function(Message message) onMessage;

  /// Connection status or clock estimate changed.
  final void Function() onChange;

  ConnectionStatus status = ConnectionStatus.connecting;

  /// Why the connection closed, once [status] is [ConnectionStatus.closed].
  String? closeReason;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _sub;
  Timer? _clockTimer;
  int _seq = 0;
  int _pingsSent = 0;

  /// The ping in flight and its exact local send time.
  String? _pingId;
  double _pingT0 = 0;
  bool _disposed = false;

  void connect() {
    final channel = WebSocketChannel.connect(wsUri(server, room, token));
    _channel = channel;
    _sub = channel.stream.listen(
      _onData,
      onError: (Object e) => closeReason ??= _describe(e),
      onDone: _onDone,
    );
    channel.ready.then(
      (_) {
        if (_disposed) return;
        status = ConnectionStatus.handshaking;
        _send(HelloMsg(clientId: clientId, name: name, ver: clientVersion));
        onChange();
      },
      onError: (Object e) {
        closeReason ??= _describe(e);
      },
    );
  }

  /// Sends `intent` with a fresh correlation id and returns that id.
  String sendIntent(String op, [Map<String, Object?> args = const {}]) {
    final id = 'i$_seq-${_randomHex(3)}';
    _send(IntentMsg(op: op, args: args), id: id);
    return id;
  }

  void sendReport(double driftMs) {
    _send(
      ReportMsg(
        activityId: null,
        observed: Observed(
          offsetMs: clock.offsetMs,
          rttMs: clock.rttMs,
          driftMs: driftMs,
          source: 'flutter',
        ),
      ),
    );
  }

  /// Closes the socket. No callbacks fire afterwards.
  Future<void> close() async {
    _disposed = true;
    _clockTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
  }

  void _onData(Object? data) {
    final text = switch (data) {
      String s => s,
      List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    final message = text == null ? null : decodeMessage(text);
    if (message == null || _disposed) return;
    switch (message.body) {
      case WelcomeMsg():
        status = ConnectionStatus.joined;
        _startBurst();
        _clockTimer?.cancel();
        _clockTimer = Timer.periodic(clockRefreshEvery, (_) => _startBurst());
        onMessage(message);
        onChange();
      case ClockPongMsg pong:
        _onPong(pong);
      default:
        onMessage(message);
    }
  }

  void _onDone() {
    _clockTimer?.cancel();
    status = ConnectionStatus.closed;
    closeReason = switch (_channel?.closeCode) {
      4001 => 'server refused the join token (4001: invalid or expired)',
      4004 => 'room not found (4004)',
      null => closeReason ?? 'connection closed',
      final code => 'connection closed (code $code${_reason()})',
    };
    if (!_disposed) onChange();
  }

  String _reason() {
    final r = _channel?.closeReason;
    return r == null || r.isEmpty ? '' : ': $r';
  }

  void _startBurst() {
    clock.restartBurst();
    _sendPing();
  }

  void _sendPing() {
    final id = 'p${_pingsSent++}';
    final t0 = clock.localMs();
    _pingId = id;
    _pingT0 = t0;
    _send(ClockPingMsg(pingId: id, t0: t0.floor()));
  }

  void _onPong(ClockPongMsg pong) {
    if (pong.pingId != _pingId) return;
    final t3 = clock.localMs();
    _pingId = null;
    if (clock.ingest(_pingT0, pong.t1.toDouble(), pong.t2.toDouble(), t3)) {
      onChange();
    } else {
      _sendPing();
    }
  }

  void _send(Body body, {String? id}) {
    final channel = _channel;
    if (channel == null || _disposed || status == ConnectionStatus.closed) return;
    final env = Envelope(room: room, seq: _seq++, ts: clock.serverNow(), from: clientId, id: id);
    channel.sink.add(encodeMessage(env, body));
  }
}

String _describe(Object e) => e is WebSocketChannelException ? (e.message ?? '$e') : '$e';

String _randomHex(int bytes) {
  final rng = Random.secure();
  return [for (var i = 0; i < bytes; i++) rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}
