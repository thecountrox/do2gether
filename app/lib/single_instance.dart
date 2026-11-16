import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Keeps one app window alive per desktop session and forwards invite links to it.
///
/// The first instance binds a loopback port; every later launch (which is what clicking a
/// `do2gether://` link does when the app is already open) connects, hands over its invite, and exits.
class SingleInstance {
  SingleInstance({this.port = defaultPort});

  /// The instance that reads `DO2GETHER_INSTANCE_PORT`: an agent desktop (or a second profile) can
  /// run its own window side by side instead of handing its invite to the user's session.
  factory SingleInstance.fromEnvironment([Map<String, String>? env]) {
    final raw = (env ?? Platform.environment)['DO2GETHER_INSTANCE_PORT'];
    return SingleInstance(port: parsePort(raw) ?? defaultPort);
  }

  static const int defaultPort = 45871;

  static int? parsePort(String? raw) {
    final n = int.tryParse((raw ?? '').trim());
    return n != null && n > 1024 && n < 65536 ? n : null;
  }

  final int port;

  ServerSocket? _socket;

  /// Invites forwarded by later launches while this instance is running.
  final StreamController<String> _invites = StreamController<String>.broadcast();

  Stream<String> get invites => _invites.stream;

  /// Returns true when this process owns the instance and should keep running.
  Future<bool> claim() async {
    try {
      _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false);
    } on Object {
      return false;
    }
    _socket!.listen((client) async {
      try {
        final text = await client
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 2));
        final invite = text.trim();
        if (invite.isNotEmpty) _invites.add(invite);
      } on Object {
        // A mangled handoff is not worth failing over.
      } finally {
        await client.close();
      }
    }, onError: (Object _) {});
    return true;
  }

  /// Hands [invite] to the running instance. Returns false when nobody is listening.
  Future<bool> forward(String? invite) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 600),
      );
      if (invite != null && invite.isNotEmpty) socket.write(invite);
      await socket.flush();
      await socket.close();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> close() async {
    await _socket?.close();
    await _invites.close();
  }
}
