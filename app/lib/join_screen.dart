import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'room_client.dart';
import 'room_screen.dart';

const String defaultServerUrl = 'https://watch.141.253.97.15.sslip.io';

/// Null if [value] is an absolute `http`/`https` URL with a host, else the error to show.
String? validateServerUrl(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  final ok = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  return ok ? null : 'Enter an http:// or https:// server URL';
}

String? _required(String? value, String what) =>
    (value ?? '').trim().isEmpty ? '$what is required' : null;

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _form = GlobalKey<FormState>();
  final _serverField = GlobalKey<FormFieldState<String>>();
  final _server = TextEditingController(text: defaultServerUrl);
  final _room = TextEditingController();
  final _token = TextEditingController();
  final _name = TextEditingController(text: Platform.localHostname);
  String? _hostId;
  String? _createdRoom;
  String? _createdToken;
  bool _creating = false;

  @override
  void dispose() {
    for (final c in [_server, _room, _token, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (!_serverField.currentState!.validate()) return;
    setState(() => _creating = true);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final created = await _postRooms(client, Uri.parse(_server.text.trim()))
          .timeout(const Duration(seconds: 15));
      _room.text = created.roomId;
      _token.text = created.token;
      _hostId = created.hostId;
      _createdRoom = created.roomId;
      _createdToken = created.token;
    } on Object catch (e) {
      _snack('Create room failed: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<({String roomId, String token, String hostId})> _postRooms(HttpClient client, Uri server) async {
    final request = await client.postUrl(roomsUri(server));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.created && response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final json = jsonDecode(body);
    if (json case {'room_id': String roomId, 'join_token': String token, 'host_id': String hostId}) {
      return (roomId: roomId, token: token, hostId: hostId);
    }
    throw const FormatException('unexpected response from POST /rooms');
  }

  void _join() {
    if (!_form.currentState!.validate()) return;
    final name = _name.text.trim();
    final hostId = _room.text.trim() == _createdRoom && _token.text.trim() == _createdToken ? _hostId : null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoomScreen(
          server: Uri.parse(_server.text.trim()),
          room: _room.text.trim(),
          token: _token.text.trim(),
          name: name.isEmpty ? Platform.localHostname : name,
          clientId: hostId,
        ),
      ),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('watch-together')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                TextFormField(
                  key: _serverField,
                  controller: _server,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                  validator: validateServerUrl,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _room,
                  decoration: const InputDecoration(labelText: 'Room id'),
                  validator: (v) => _required(v, 'Room id'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _token,
                  decoration: const InputDecoration(labelText: 'Token'),
                  validator: (v) => _required(v, 'Token'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: _creating ? null : _createRoom,
                      child: Text(_creating ? 'Creating…' : 'Create room'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: _join, child: const Text('Join')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
