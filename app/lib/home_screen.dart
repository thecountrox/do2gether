import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'links.dart';
import 'room_client.dart';
import 'room_screen.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';
import 'widgets/sparkles.dart';

const String defaultServerUrl = 'https://watch.141.253.97.15.sslip.io';

String? validateServerUrl(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  return uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty
      ? null
      : 'Enter an http:// or https:// server URL';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _invite = TextEditingController();
  final _server = TextEditingController(text: defaultServerUrl);
  InviteLink? _parsed;
  String? _error;
  bool _creating = false;

  @override
  void dispose() {
    _invite.dispose();
    _server.dispose();
    super.dispose();
  }

  String get _name =>
      Platform.localHostname == 'localhost' ? 'You' : Platform.localHostname;

  void _enter(InviteLink link, {String? hostId}) {
    Navigator.of(context).push(
      wtRoute(
        RoomScreen(
          server: Uri.parse(_server.text.trim()),
          room: link.room,
          token: link.token,
          name: _name,
          clientId: hostId,
        ),
      ),
    );
  }

  Future<void> _createRoom() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(
        roomsUri(Uri.parse(_server.text.trim())),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.created &&
          response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final json = jsonDecode(body);
      if (json case {
        'room_id': String room,
        'join_token': String token,
        'host_id': String hostId,
      }) {
        if (!mounted) return;
        _roomReady((room: room, token: token), hostId);
      } else {
        throw const FormatException('unexpected response from POST /rooms');
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Create room failed: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _creating = false);
    }
  }

  void _roomReady(InviteLink link, String hostId) {
    final url = inviteUrl(Uri.parse(_server.text.trim()), link.token);
    final field = TextEditingController(text: url);
    WtSheet.show<void>(
      context,
      title: 'Room ready',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WtCode(code: link.room),
          const SizedBox(height: 32),
          const Text('Send this link', style: TextStyle(color: WtColors.muted)),
          const SizedBox(height: 8),
          WtField(controller: field, readOnly: true, icon: Icons.link),
          const SizedBox(height: 12),
          WtButton(
            label: 'Copy link',
            style: WtButtonStyle.ghost,
            icon: Icons.copy,
            fullWidth: true,
            onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          ),
          const SizedBox(height: 16),
          WtButton(
            label: 'Enter room',
            fullWidth: true,
            onPressed: () {
              Navigator.of(context).pop();
              _enter(link, hostId: hostId);
            },
          ),
          const SizedBox(height: 8),
          WtButton(
            label: 'Done',
            style: WtButtonStyle.ghost,
            fullWidth: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ).whenComplete(field.dispose);
  }

  void _serverSheet() {
    final draft = TextEditingController(text: _server.text);
    String? error;
    WtSheet.show<void>(
      context,
      title: 'Server',
      child: StatefulBuilder(
        builder: (context, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WtField(
              controller: draft,
              hint: 'Server URL',
              icon: Icons.dns_outlined,
              onChanged: (_) => update(() => error = null),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(color: WtColors.danger)),
            ],
            const SizedBox(height: 20),
            WtButton(
              label: 'Save',
              fullWidth: true,
              onPressed: () {
                final validation = validateServerUrl(draft.text);
                if (validation != null) {
                  update(() => error = validation);
                  return;
                }
                setState(() {
                  _server.text = draft.text.trim();
                  _error = null;
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    ).whenComplete(draft.dispose);
  }

  @override
  Widget build(BuildContext context) => WtScaffold(
    child: WtBackground(
      child: Stack(
        children: [
          const Positioned.fill(child: WtSparkles()),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: ShaderMask(
                              blendMode: BlendMode.srcIn,
                              shaderCallback: (bounds) => const LinearGradient(
                                colors: [WtColors.pink, WtColors.cyan],
                              ).createShader(bounds),
                              child: Text(
                                'watch together',
                                style: Theme.of(context).textTheme.displayLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 5, bottom: 7),
                            child: Icon(
                              Icons.auto_awesome,
                              size: 15,
                              color: WtColors.star,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'One screen. Same moment.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: WtColors.muted, fontSize: 15),
                    ),
                    const SizedBox(height: 48),
                    const Text(
                      'INVITE LINK',
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1,
                        color: WtColors.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    WtField(
                      controller: _invite,
                      hint: 'Paste your invite link',
                      icon: Icons.link,
                      onChanged: (value) => setState(() {
                        _parsed = parseInviteLink(value);
                        _error = null;
                      }),
                      onSubmitted: (_) {
                        if (_parsed != null) _enter(_parsed!);
                      },
                    ),
                    if (_parsed != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '● ${_parsed!.room}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: WtColors.live,
                        ),
                      ),
                    ] else if (_invite.text.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Enter a valid invite link or room code and token',
                        style: TextStyle(fontSize: 12, color: WtColors.danger),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      WtBanner(message: _error!),
                    ],
                    const SizedBox(height: 24),
                    WtButton(
                      label: 'Join a room',
                      fullWidth: true,
                      onPressed: _parsed == null
                          ? null
                          : () => _enter(_parsed!),
                    ),
                    const SizedBox(height: 24),
                    const Row(
                      children: [
                        Expanded(child: Divider(color: Color(0x33FFFFFF))),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'or',
                            style: TextStyle(color: WtColors.muted),
                          ),
                        ),
                        Expanded(child: Divider(color: Color(0x33FFFFFF))),
                      ],
                    ),
                    const SizedBox(height: 24),
                    WtButton(
                      label: _creating ? 'Creating…' : 'Start a room',
                      style: WtButtonStyle.ghost,
                      fullWidth: true,
                      onPressed: _creating ? null : _createRoom,
                    ),
                    const SizedBox(height: 48),
                    Center(
                      child: TextButton(
                        onPressed: _serverSheet,
                        child: Text(
                          'Server · Change',
                          style: const TextStyle(
                            fontSize: 12,
                            color: WtColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
