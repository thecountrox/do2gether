/// The Jellyfin dialog on Home: sign in, then pick a movie as this viewer's copy.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'format.dart';
import 'jellyfin.dart';
import 'local_copy.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';

/// Resolves to the picked movie as a remote copy, or null when closed. With a [session] it opens
/// on the movie list; without one, on the sign-in form.
Future<LocalCopy?> showJellyfinPicker(
  BuildContext context, {
  required JellyfinApi api,
  required JellyfinSession? session,
  required ValueChanged<JellyfinSession> onSession,
}) => showDialog<LocalCopy>(
  context: context,
  barrierColor: const Color(0x8C000000),
  builder: (_) =>
      JellyfinDialog(api: api, session: session, onSession: onSession),
);

class JellyfinDialog extends StatefulWidget {
  const JellyfinDialog({
    super.key,
    required this.api,
    required this.session,
    required this.onSession,
  });
  final JellyfinApi api;
  final JellyfinSession? session;

  /// A sign-in succeeded; Home keeps it so the next open goes straight to the list.
  final ValueChanged<JellyfinSession> onSession;

  @override
  State<JellyfinDialog> createState() => _JellyfinDialogState();
}

class _JellyfinDialogState extends State<JellyfinDialog> {
  late JellyfinSession? _session = widget.session;
  late final _server = TextEditingController(
    text: widget.session?.server.toString() ?? '',
  );
  late final _user = TextEditingController(text: widget.session?.user ?? '');
  final _pass = TextEditingController();
  late bool _busy = widget.session != null;
  String? _error;
  List<JellyfinItem> _movies = const [];

  static const _muted = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: WtColors.tx3,
  );

  @override
  void initState() {
    super.initState();
    if (_session != null) unawaited(_fetchMovies());
  }

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
      if (!mounted) return;
      widget.onSession(session);
      setState(() => _session = session);
      await _fetchMovies();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _fetchMovies() async {
    try {
      final movies = await _session!.movies();
      if (mounted) {
        setState(() {
          _movies = movies;
          _busy = false;
        });
      }
    } on Object catch (e) {
      // A saved token can be revoked: back to the form, with the server's words.
      if (mounted) {
        setState(() {
          _session = null;
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  void _signInAgain() => setState(() {
    _session = null;
    _pass.clear();
    _error = null;
  });

  void _pick(JellyfinItem item) {
    final session = _session!;
    Navigator.of(context).pop(
      LocalCopy.remote(
        url: streamUrl(
          server: session.server.toString(),
          token: session.token,
          itemId: item.id,
        ),
        itemRef: jellyfinRef(session.server, item.id),
        title: item.name,
        duration: item.runtime,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Dialog(
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
                      'Jellyfin',
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
              if (session == null)
                const Text(
                  'Everyone streams from their own server. '
                  'The room only shares which movie.',
                  style: _muted,
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Signed in as ${session.user} on ${session.server.host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _muted,
                      ),
                    ),
                    WtTextButton(
                      label: 'Change',
                      compact: true,
                      onPressed: _busy ? null : _signInAgain,
                    ),
                  ],
                ),
              const SizedBox(height: 16),
              if (session == null) ..._form() else ..._list(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _form() => [
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
              _ErrorText(_error!),
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
  ];

  List<Widget> _list() {
    if (_busy) {
      return const [Text('Loading movies…', style: _muted)];
    }
    if (_movies.isEmpty) {
      return const [Text('No movies on this server yet.', style: _muted)];
    }
    return [
      const WtLabel('Pick a movie'),
      const SizedBox(height: 8),
      Flexible(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _movies.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) =>
                _MovieRow(item: _movies[i], onTap: () => _pick(_movies[i])),
          ),
        ),
      ),
    ];
  }

  void _clearError(String _) {
    if (_error != null) setState(() => _error = null);
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: WtColors.yellow,
    ),
  );
}

class _MovieRow extends StatelessWidget {
  const _MovieRow({required this.item, required this.onTap});
  final JellyfinItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final runtime = item.runtime;
    final time = runtime == null ? null : fmtTime(runtime.inMilliseconds);
    return WtTap(
      onTap: onTap,
      semanticLabel: time == null ? item.name : '${item.name}, $time',
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: WtColors.plum,
          borderRadius: BorderRadius.circular(WtRadius.control),
          border: Border.all(color: WtColors.line, width: 2),
        ),
        child: Row(
          children: [
            const WtFileGlyph(size: 22, color: WtColors.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: WtColors.text,
                ),
              ),
            ),
            if (time != null) ...[
              const SizedBox(width: 10),
              Text(
                time,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: WtColors.tx3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
