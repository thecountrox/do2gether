/// The "Room ready" dialog shown over Home after `POST /rooms`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'links.dart';
import 'local_copy.dart';
import 'room_api.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';
import 'widgets/identity.dart';

/// Resolves to true when the host pressed `Enter room`.
Future<bool?> showRoomReady(
  BuildContext context, {
  required Uri server,
  required CreatedRoom created,
  required String name,
  required LocalCopy? copy,
  required RoomApi api,
  required PickCopy pickCopy,
  required ValueChanged<LocalCopy> onCopy,
}) => showDialog<bool>(
  context: context,
  barrierColor: const Color(0x8C000000),
  builder: (_) => RoomReadyDialog(
    server: server,
    created: created,
    name: name,
    copy: copy,
    api: api,
    pickCopy: pickCopy,
    onCopy: onCopy,
  ),
);

enum _Readiness { ready, joined, invited, noFile }

class RoomReadyDialog extends StatefulWidget {
  const RoomReadyDialog({
    super.key,
    required this.server,
    required this.created,
    required this.name,
    required this.copy,
    required this.api,
    required this.pickCopy,
    required this.onCopy,
    this.pollEvery = const Duration(seconds: 3),
  });
  final Uri server;
  final CreatedRoom created;
  final String name;
  final LocalCopy? copy;
  final RoomApi api;
  final PickCopy pickCopy;
  final ValueChanged<LocalCopy> onCopy;
  final Duration pollEvery;

  @override
  State<RoomReadyDialog> createState() => _RoomReadyDialogState();
}

class _RoomReadyDialogState extends State<RoomReadyDialog> {
  late final String _url = inviteUrl(widget.server, widget.created.token);
  late final TextEditingController _field = TextEditingController(text: _url);
  late final int? _expiresAt = tokenExpiryMs(widget.created.token);
  late LocalCopy? _copy = widget.copy;
  List<String> _others = const [];
  bool _copied = false;
  bool _shared = false;
  bool _nudged = false;
  bool _picking = false;
  final List<Timer> _flashes = [];
  late final Timer _tick;
  late final Timer _poll;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_expiresAt != null) setState(() {});
    });
    _poll = Timer.periodic(widget.pollEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _tick.cancel();
    _poll.cancel();
    for (final t in _flashes) {
      t.cancel();
    }
    _field.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final info = await widget.api.lookup(widget.server, widget.created.room);
      if (!mounted || info == null) return;
      final others = [
        for (final n in info.memberNames)
          if (n != widget.name) n,
      ];
      setState(() => _others = others);
    } on Object {
      // Readiness is a nicety; the dialog keeps working without it.
    }
  }

  /// Shows a "Copied" state for 1.5 s.
  void _flash(void Function(bool) set) {
    setState(() => set(true));
    _flashes.add(
      Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => set(false));
      }),
    );
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: _url));
    _flash((v) => _copied = v);
  }

  void _share() {
    final code = codeGroups(widget.created.room).join('-').toUpperCase();
    Clipboard.setData(
      ClipboardData(
        text:
            'Watch with me on watch·together — room $code\n$_url\n'
            'Open the same file on your side and press join.',
      ),
    );
    _flash((v) => _shared = v);
  }

  void _nudge() {
    Clipboard.setData(ClipboardData(text: _url));
    _flash((v) => _nudged = v);
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final copy = await widget.pickCopy();
      if (copy != null && mounted) {
        setState(() => _copy = copy);
        widget.onCopy(copy);
      }
    } on Object {
      // Picker closed or the file could not be read; keep the old choice.
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String get _quietLine {
    final exp = _expiresAt;
    if (exp == null) return 'Anyone in the room can invite';
    final left = exp - DateTime.now().millisecondsSinceEpoch;
    return left <= 0
        ? 'Code expired · anyone in the room can invite'
        : 'Code expires in ${fmtTime(left)} · anyone in the room can invite';
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.created.room;
    final rows = <(String, String, _Readiness, bool)>[
      (
        widget.created.hostId,
        widget.name,
        _copy == null ? _Readiness.noFile : _Readiness.ready,
        true,
      ),
      for (final n in _others) (n, n, _Readiness.joined, false),
      if (_others.isEmpty) ('invited', 'Your friends', _Readiness.invited, false),
    ];
    final ready = _copy == null ? 0 : 1;
    final total = 1 + _others.length;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 520,
        decoration: BoxDecoration(
          color: WtColors.plum2,
          borderRadius: BorderRadius.circular(WtRadius.surface),
          border: Border.all(color: WtColors.line, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0xB3000000),
              offset: Offset(0, 30),
              blurRadius: 70,
              spreadRadius: -20,
            ),
          ],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WtRadius.surface - 2),
            gradient: const RadialGradient(
              center: Alignment(0, -1.2),
              radius: 0.9,
              colors: [Color(0x40D93583), Color(0x00D93583)],
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 22, 26, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 18),
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      WtKeyCaps(code: code, size: WtKeySize.large),
                      const Positioned(left: -14, top: -8, child: WtSpark(size: 16)),
                      const Positioned(
                        right: -12,
                        bottom: -4,
                        child: WtSpark(size: 11, color: WtColors.text),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  codeIsUnambiguous(code)
                      ? 'read it out — no 0/O or 1/I'
                      : 'read it out, letter by letter',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WtColors.tx3,
                  ),
                ),
                const SizedBox(height: 18),
                WtField(
                  controller: _field,
                  readOnly: true,
                  height: 56,
                  icon: Icons.link,
                  iconColor: WtColors.tx3,
                  trailing: _CopyButton(copied: _copied, onTap: _copyLink),
                ),
                const SizedBox(height: 20),
                WtLabel(
                  "Who's coming",
                  trailing: Text(
                    '$ready of $total ready',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: WtColors.tx3,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                for (var i = 0; i < rows.length; i++)
                  _PersonRow(
                    id: rows[i].$1,
                    name: rows[i].$2,
                    state: rows[i].$3,
                    you: rows[i].$4,
                    nudge: i == rows.length - 1 && !rows[i].$4
                        ? (_nudged ? 'Link copied' : 'Nudge')
                        : null,
                    onNudge: _nudge,
                  ),
                const SizedBox(height: 12),
                _CopyRow(copy: _copy, onChoose: _picking ? null : _pick),
                const SizedBox(height: 20),
                Row(
                  children: [
                    SizedBox(
                      width: 200,
                      child: WtButton(
                        label: _shared ? 'Copied' : 'Share',
                        icon: _shared ? Icons.check_rounded : Icons.send_rounded,
                        style: WtButtonStyle.ghost,
                        size: WtButtonSize.large,
                        fullWidth: true,
                        onPressed: _share,
                        tooltip: 'Copy an invite message for Discord',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: WtButton(
                        label: 'Enter room',
                        trailingIcon: Icons.arrow_forward_rounded,
                        size: WtButtonSize.large,
                        fullWidth: true,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  _quietLine,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WtColors.tx3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    const title = TextStyle(
      fontSize: 26,
      height: 1.15,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.4,
      color: WtColors.text,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Room ', style: title),
                  WtGradientText('ready', style: title),
                ],
              ),
              SizedBox(height: 4),
              Text(
                'Send the code or the link. Everyone opens their own copy.',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: WtColors.tx3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        WtIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.copied, required this.onTap});
  final bool copied;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = copied ? WtColors.plum : WtColors.text;
    return WtTap(
      onTap: onTap,
      radius: 14,
      semanticLabel: copied ? 'Copied' : 'Copy invite link',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 42,
        constraints: const BoxConstraints(minWidth: 118),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: copied ? WtColors.text : WtColors.s2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: WtColors.line, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(copied ? Icons.check_rounded : Icons.copy_rounded, size: 18, color: fg),
            const SizedBox(width: 8),
            Text(
              copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.id,
    required this.name,
    required this.state,
    required this.you,
    required this.nudge,
    required this.onNudge,
  });
  final String id;
  final String name;
  final _Readiness state;
  final bool you;
  final String? nudge;
  final VoidCallback onNudge;

  @override
  Widget build(BuildContext context) {
    final chip = switch (state) {
      _Readiness.ready => const WtPill(
        label: 'Ready',
        tone: WtTone.live,
        dot: WtDotStyle.solid,
        height: 28,
        fontSize: 13,
      ),
      _Readiness.joined => const WtPill(
        label: 'Joined',
        height: 28,
        fontSize: 13,
      ),
      _Readiness.invited => const WtPill(
        label: 'Invited',
        tone: WtTone.warn,
        dot: WtDotStyle.ring,
        height: 28,
        fontSize: 13,
      ),
      _Readiness.noFile => const WtPill(
        label: 'No file yet',
        tone: WtTone.quiet,
        height: 28,
        fontSize: 13,
      ),
    };
    return SizedBox(
      height: 50,
      child: Row(
        children: [
          WtAvatar(
            id: id,
            name: state == _Readiness.invited ? '+' : name,
            muted: state == _Readiness.invited,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: name,
                children: [
                  if (you)
                    const TextSpan(
                      text: '  (you)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: WtColors.tx3,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: WtColors.text,
              ),
            ),
          ),
          chip,
          if (nudge != null) ...[
            const SizedBox(width: 4),
            WtTextButton(label: nudge!, compact: true, onPressed: onNudge),
          ],
        ],
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.copy, required this.onChoose});
  final LocalCopy? copy;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final copy = this.copy;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WtColors.s1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: WtColors.plum,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: WtColors.line, width: 2),
            ),
            child: const WtFileGlyph(size: 24, color: WtColors.pink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (copy == null)
                  const Text(
                    'Your copy',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: WtColors.text,
                    ),
                  )
                else
                  WtMidText(
                    copy.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: WtColors.text,
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  copy == null
                      ? 'Plays from your disk'
                      : '${copy.details} · Plays from your disk',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WtColors.tx3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          WtButton(
            label: copy == null ? 'Choose your copy' : 'Change',
            style: WtButtonStyle.ghost,
            size: WtButtonSize.small,
            onPressed: onChoose,
          ),
        ],
      ),
    );
  }
}
