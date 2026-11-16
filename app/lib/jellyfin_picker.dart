/// The Jellyfin sign-in form: what the library's Jellyfin source shows from `ensureReady`.
library;

import 'package:flutter/material.dart';

import 'jellyfin.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';

/// Resolves to the new session, or null when closed. [previous] pre-fills server and user.
Future<JellyfinSession?> showJellyfinSignIn(
  BuildContext context, {
  required JellyfinApi api,
  JellyfinSession? previous,
}) => showDialog<JellyfinSession>(
  context: context,
  barrierColor: const Color(0x8C000000),
  builder: (_) => JellyfinDialog(api: api, previous: previous),
);

class JellyfinDialog extends StatefulWidget {
  const JellyfinDialog({super.key, required this.api, this.previous});
  final JellyfinApi api;
  final JellyfinSession? previous;

  @override
  State<JellyfinDialog> createState() => _JellyfinDialogState();
}

class _JellyfinDialogState extends State<JellyfinDialog> {
  late final _server = TextEditingController(
    text: widget.previous?.server.toString() ?? '',
  );
  late final _user = TextEditingController(text: widget.previous?.user ?? '');
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  static const _muted = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: WtColors.tx3,
  );

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final problem =
        validateJellyfinServer(_server.text) ??
        (_user.text.trim().isEmpty ? 'Enter your Jellyfin user name' : null);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.api.connect(
        server: Uri.parse(_server.text.trim()),
        user: _user.text.trim(),
        pass: _pass.text,
      );
      if (mounted) Navigator.of(context).pop(session);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: WtColors.plum2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(WtRadius.surface),
      side: const BorderSide(color: WtColors.line, width: 2),
    ),
    child: SizedBox(
      width: 460,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Connect Jellyfin',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                WtIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Everyone streams from their own server. '
              'The room only shares which movie.',
              style: _muted,
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const WtLabel('Server'),
                    const SizedBox(height: 8),
                    WtField(
                      controller: _server,
                      hint: 'https://jellyfin.example',
                      icon: Icons.dns_outlined,
                      height: 56,
                      autofocus: _server.text.isEmpty,
                      onChanged: _clearError,
                      onSubmitted: (_) => _connect(),
                    ),
                    const SizedBox(height: 14),
                    const WtLabel('User'),
                    const SizedBox(height: 8),
                    WtField(
                      controller: _user,
                      hint: 'Your Jellyfin user',
                      icon: Icons.person_outline,
                      height: 56,
                      onChanged: _clearError,
                      onSubmitted: (_) => _connect(),
                    ),
                    const SizedBox(height: 14),
                    const WtLabel('Password'),
                    const SizedBox(height: 8),
                    WtField(
                      controller: _pass,
                      hint: 'Leave empty if there is none',
                      icon: Icons.lock_outline,
                      height: 56,
                      obscure: true,
                      autofocus: _server.text.isNotEmpty,
                      onChanged: _clearError,
                      onSubmitted: (_) => _connect(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: WtColors.yellow,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: WtButton(
                label: _busy ? 'Connecting…' : 'Connect',
                onPressed: _busy ? null : _connect,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _clearError(String _) {
    if (_error != null) setState(() => _error = null);
  }
}
