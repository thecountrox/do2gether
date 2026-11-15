import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'links.dart';
import 'local_copy.dart';
import 'room_api.dart';
import 'room_ready.dart';
import 'room_screen.dart';
import 'theme.dart';
import 'widgets/button.dart';
import 'widgets/chrome.dart';
import 'widgets/field.dart';
import 'widgets/identity.dart';

const String defaultServerUrl = 'https://watch.141.253.97.15.sslip.io';

const Key homeCardKey = ValueKey('home-card');

String? validateServerUrl(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  return uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty
      ? null
      : 'Enter an http:// or https:// server URL';
}

/// Where the pasted invite stands after parsing and `GET /rooms/{id}`.
enum InviteState {
  empty,
  malformed,
  checking,
  found,
  unchecked,
  expired,
  ended,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.api = const HttpRoomApi(),
    this.pickCopy = pickLocalCopy,
    this.initialInvite,
  });
  final RoomApi api;
  final PickCopy pickCopy;

  /// Invite URL the app was launched with, if any.
  final String? initialInvite;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _invite = TextEditingController();
  String _server = defaultServerUrl;
  String _name = Platform.localHostname == 'localhost'
      ? 'You'
      : Platform.localHostname;
  int? _rtt;
  bool _offline = false;
  InviteLink? _link;
  InviteState _state = InviteState.empty;
  RoomInfo? _info;
  int _lookupSeq = 0;
  LocalCopy? _copy;
  bool _picking = false;
  bool _creating = false;
  String? _createError;

  Uri get _serverUri => Uri.parse(_server);

  @override
  void initState() {
    super.initState();
    unawaited(_ping());
    final invite = widget.initialInvite;
    if (invite != null && invite.isNotEmpty) {
      _invite.text = invite;
      _onInvite(invite);
    }
  }

  @override
  void dispose() {
    _invite.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    setState(() {
      _rtt = null;
      _offline = false;
    });
    final server = _server;
    try {
      final rtt = await widget.api.ping(_serverUri);
      if (mounted && server == _server) setState(() => _rtt = rtt);
    } on Object {
      if (mounted && server == _server) setState(() => _offline = true);
    }
  }

  void _onInvite(String text) {
    final link = parseInviteLink(text);
    final seq = ++_lookupSeq;
    setState(() {
      _link = link;
      _info = null;
      _state = text.trim().isEmpty
          ? InviteState.empty
          : link == null
          ? InviteState.malformed
          : InviteState.checking;
    });
    if (link != null) unawaited(_lookup(link, seq));
  }

  Future<void> _lookup(InviteLink link, int seq) async {
    InviteState state;
    RoomInfo? info;
    try {
      info = await widget.api.lookup(_serverUri, link.room);
      final exp = tokenExpiryMs(link.token);
      state = info == null
          ? InviteState.ended
          : exp != null && exp <= DateTime.now().millisecondsSinceEpoch
          ? InviteState.expired
          : InviteState.found;
    } on Object {
      // Fail open: the code is still shown and joining stays possible.
      state = InviteState.unchecked;
    }
    if (!mounted || seq != _lookupSeq) return;
    setState(() {
      _state = state;
      _info = info;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _invite.text = text;
    _onInvite(text);
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final copy = await widget.pickCopy();
      if (copy != null && mounted) setState(() => _copy = copy);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't open that file: $e")));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  bool get _linkUsable =>
      _link != null &&
      (_state == InviteState.found ||
          _state == InviteState.unchecked ||
          _state == InviteState.checking);

  bool get _canJoin =>
      _copy != null &&
      _link != null &&
      (_state == InviteState.found || _state == InviteState.unchecked);

  void _join() {
    if (!_canJoin) return;
    _enter(_link!, copy: _copy);
  }

  void _enter(InviteLink link, {String? hostId, LocalCopy? copy}) {
    Navigator.of(context).push(
      wtRoute(
        RoomScreen(
          server: _serverUri,
          room: link.room,
          token: link.token,
          name: _name,
          clientId: hostId,
          initialFile: copy?.path,
        ),
      ),
    );
  }

  Future<void> _createRoom() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final created = await widget.api.create(_serverUri);
      if (!mounted) return;
      setState(() => _creating = false);
      final enter = await showRoomReady(
        context,
        server: _serverUri,
        created: created,
        name: _name,
        copy: _copy,
        api: widget.api,
        pickCopy: widget.pickCopy,
        onCopy: (copy) => setState(() => _copy = copy),
      );
      if (enter == true && mounted) {
        _enter(
          (room: created.room, token: created.token),
          hostId: created.hostId,
          copy: _copy,
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => _createError = '$e');
    } finally {
      if (mounted && _creating) setState(() => _creating = false);
    }
  }

  void _askForNewLink() {
    final host = _info?.hostName;
    final code = _link?.room ?? '';
    Clipboard.setData(
      ClipboardData(
        text:
            'My watch·together invite for room $code expired — '
            'could you send a fresh link?',
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          host == null
              ? 'Message copied — paste it to whoever invited you'
              : 'Message copied — paste it to $host',
        ),
      ),
    );
  }

  Future<void> _changeServer() async {
    final value = await promptText(
      context,
      title: 'Server',
      initial: _server,
      hint: 'https://…',
      icon: Icons.dns_outlined,
      validate: validateServerUrl,
    );
    if (value == null || !mounted) return;
    setState(() => _server = value);
    unawaited(_ping());
    if (_link != null) _onInvite(_invite.text);
  }

  Future<void> _changeName() async {
    final value = await promptText(
      context,
      title: 'Your name',
      initial: _name,
      hint: 'What friends call you',
      icon: Icons.person_outline,
      validate: (v) =>
          (v ?? '').trim().isEmpty ? 'Enter a name others will see' : null,
    );
    if (value != null && mounted) setState(() => _name = value);
  }

  int get _nextStep => !_linkUsable
      ? 0
      : _copy == null
      ? 1
      : 2;

  @override
  Widget build(BuildContext context) => WtScaffold(
    child: Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: WtBackdrop(
        child: LayoutBuilder(
          builder: (context, box) {
            final inner = box.maxWidth - 2 * WtSpace.window;
            final gap = ((inner - 320 - 504) / 3).clamp(48.0, 144.0);
            final brandHeight = (box.maxHeight - 2 * WtSpace.window).clamp(
              0.0,
              640.0,
            );
            final compact = box.maxWidth < wtCompactWidth;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(WtSpace.window),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: box.maxHeight - 2 * WtSpace.window,
                ),
                child: Center(
                  child: compact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Brand(
                              next: _nextStep,
                              status: _statusRow(),
                              compact: true,
                            ),
                            const SizedBox(height: 32),
                            _card(),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 320,
                              height: brandHeight,
                              child: _Brand(
                                next: _nextStep,
                                status: _statusRow(),
                              ),
                            ),
                            SizedBox(width: gap),
                            SizedBox(width: 504, child: _card()),
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  /// Ctrl+V anywhere on Home pastes the invite, unless a text field already has focus.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyV ||
        !HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    unawaited(_paste());
    return KeyEventResult.handled;
  }

  Widget _statusRow() {
    final host = _serverUri.host;
    final (color, style, text) = _offline
        ? (WtColors.yellow, WtDotStyle.ring, "Can't reach $host")
        : _rtt == null
        ? (WtColors.tx3, WtDotStyle.ring, 'Connecting to $host…')
        : (WtColors.cyan, WtDotStyle.solid, 'Connected to $host · $_rtt ms');
    return Row(
      children: [
        WtDot(color: color, style: style),
        const SizedBox(width: 10),
        Flexible(
          child: Tooltip(
            message: _server,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: WtColors.tx3,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _GhostChip(
          label: 'Change server',
          icon: Icons.dns_outlined,
          onTap: _changeServer,
        ),
      ],
    );
  }

  Widget _card() => Container(
    key: homeCardKey,
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
    decoration: BoxDecoration(
      color: WtColors.s1,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: WtColors.line, width: 2),
      boxShadow: const [
        BoxShadow(color: Color(0x08FFFFFF), spreadRadius: 8),
        BoxShadow(
          color: Color(0x99000000),
          offset: Offset(0, 30),
          blurRadius: 60,
          spreadRadius: -20,
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Join a room',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            _NameChip(name: _name, onTap: _changeName),
          ],
        ),
        const SizedBox(height: 18),
        WtLabel(
          'Invite link',
          trailing: const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Text(
              'Ctrl V to paste',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: WtColors.tx3,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        WtField(
          controller: _invite,
          hint: 'Paste the invite link',
          icon: Icons.link,
          onChanged: _onInvite,
          onSubmitted: (_) => _join(),
          trailing: WtIconButton(
            icon: Icons.content_paste_rounded,
            tooltip: 'Paste',
            onPressed: _paste,
          ),
        ),
        const SizedBox(height: 12),
        ..._inviteBody(),
        const SizedBox(height: 16),
        _cta(),
        const SizedBox(height: 18),
        const Divider(height: 2, thickness: 2, color: WtColors.line),
        const SizedBox(height: 16),
        Row(
          children: [
            WtButton(
              label: _creating ? 'Starting…' : 'Start a room',
              icon: Icons.add,
              style: WtButtonStyle.ghost,
              size: WtButtonSize.small,
              onPressed: _creating ? null : _createRoom,
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Text(
                'Host and send your own link.',
                maxLines: 2,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: WtColors.tx3,
                ),
              ),
            ),
          ],
        ),
        if (_createError != null) ...[
          const SizedBox(height: 10),
          _CalmLine(
            icon: Icons.cloud_off_outlined,
            text: "Couldn't start a room: $_createError",
          ),
        ],
      ],
    ),
  );

  List<Widget> _inviteBody() {
    final link = _link;
    switch (_state) {
      case InviteState.empty:
        return const [
          _CalmLine(
            icon: Icons.info_outline,
            text:
                'Paste the whole message from Discord. '
                'The link already knows the server.',
          ),
        ];
      case InviteState.malformed:
        return const [
          _CalmLine(
            icon: Icons.link_off,
            text:
                'That link looks cut off. Invites end in a code like '
                '…/join/eyJy…  — try copying the whole message again.',
          ),
        ];
      case InviteState.expired:
        final info = _info!;
        return [
          WtAlert(
            icon: Icons.schedule,
            title: 'This link expired, but the room is still running',
            body:
                '${info.hostName ?? 'Whoever invited you'} can send a fresh one.',
            actions: [
              Row(
                children: [
                  WtPill(
                    label: 'Live now · ${info.memberCount} inside',
                    tone: WtTone.live,
                    dot: WtDotStyle.pulse,
                    height: 28,
                    fontSize: 13,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: WtButton(
                      label: 'Ask for a new link',
                      style: WtButtonStyle.ghost,
                      size: WtButtonSize.small,
                      onPressed: _askForNewLink,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ];
      case InviteState.ended:
        return [
          WtAlert(
            icon: Icons.stop_circle_outlined,
            title: 'This room has ended',
            body: 'Start a new one and send your own link.',
            actions: [
              WtButton(
                label: 'Start a room',
                icon: Icons.add,
                style: WtButtonStyle.ghost,
                size: WtButtonSize.small,
                onPressed: _creating ? null : _createRoom,
              ),
            ],
          ),
        ];
      case InviteState.checking || InviteState.found || InviteState.unchecked:
        return [
          _FoundCard(room: link!.room, state: _state, info: _info, copy: _copy),
          if (_copy != null) ...[
            const SizedBox(height: 12),
            _MineRow(
              copy: _copy!,
              hostRef: _info?.itemRef,
              onChange: _picking ? null : _pick,
            ),
          ],
        ];
    }
  }

  Widget _cta() {
    final host = _info?.hostName;
    final label = host == null ? 'Join room' : "Join $host's room";
    if (_canJoin) {
      return WtButton(
        label: label,
        trailingIcon: Icons.arrow_forward_rounded,
        size: WtButtonSize.large,
        fullWidth: true,
        onPressed: _join,
      );
    }
    final needsCopy = _linkUsable && _copy == null;
    final reason = needsCopy
        ? 'Open your copy to join'
        : _state == InviteState.checking
        ? 'Checking the room…'
        : 'Paste an invite to join';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: false,
          label: '$label, disabled: $reason',
          excludeSemantics: true,
          child: WtDashed(
            color: WtColors.line,
            radius: 20,
            child: Container(
              height: 60,
              decoration: BoxDecoration(
                color: WtColors.s2,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  needsCopy
                      ? const WtFileGlyph(size: 22)
                      : const Icon(Icons.link, size: 22, color: WtColors.tx3),
                  const SizedBox(width: 10),
                  Text(
                    reason,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: WtColors.tx3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (needsCopy) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  host == null
                      ? 'Pick the same file everyone else has.'
                      : '$host is playing their copy. Pick the same file.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WtColors.tx3,
                  ),
                ),
              ),
              WtTextButton(
                label: _picking ? 'Checking…' : 'Choose file…',
                compact: true,
                onPressed: _picking ? null : _pick,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({
    required this.next,
    required this.status,
    this.compact = false,
  });

  /// Index of the step to do next; 0 paste, 1 open copy, 2 play.
  final int next;
  final Widget status;

  /// Narrow window: sized to content, steps folded behind `How it works`.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final display = Theme.of(context).textTheme.displayLarge;
    _StepState state(int i) => i < next
        ? _StepState.done
        : i == next
        ? _StepState.next
        : _StepState.todo;
    const mark = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [WtWordmark(), SizedBox(width: 6), WtSpark()],
    );
    final headline = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('One screen.', style: display),
        WtGradientText('Same moment.', style: display),
        const SizedBox(height: 16),
        const Text(
          'Everyone plays their own copy, in step. '
          'It plays from your disk — this app only keeps time.',
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: WtColors.tx3,
          ),
        ),
      ],
    );
    final steps = Column(
      children: [
        _Step(
          n: 1,
          title: 'Paste the invite',
          body:
              'The link from Discord or a friend. It already knows the server.',
          state: state(0),
        ),
        _Step(
          n: 2,
          title: 'Open your copy',
          body: 'The same file, from your own disk. We check it matches.',
          state: state(1),
        ),
        _Step(
          n: 3,
          title: 'Press play',
          body: 'Anyone can pause or skip. Everyone follows.',
          state: state(2),
          last: true,
        ),
      ],
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          const SizedBox(height: 24),
          headline,
          const SizedBox(height: 16),
          _Disclosure(label: 'How it works', child: steps),
          const SizedBox(height: 16),
          status,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [mark, headline, steps, status],
    );
  }
}

/// A ghost chip that shows or hides [child] below it.
class _Disclosure extends StatefulWidget {
  const _Disclosure({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  State<_Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<_Disclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        expanded: _open,
        child: _GhostChip(
          label: widget.label,
          icon: _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          onTap: () => setState(() => _open = !_open),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: _open
            ? Padding(
                padding: const EdgeInsets.only(top: 16),
                child: widget.child,
              )
            : const SizedBox(width: double.infinity),
      ),
    ],
  );
}

/// A small secondary control: plum chip, 2px line border, pill radius.
class _GhostChip extends StatelessWidget {
  const _GhostChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onTap,
    radius: WtRadius.pill,
    child: Container(
      height: 32,
      padding: const EdgeInsets.only(left: 10, right: 12),
      decoration: BoxDecoration(
        color: WtColors.s1,
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: WtColors.tx2),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: WtColors.text,
            ),
          ),
        ],
      ),
    ),
  );
}

enum _StepState { done, next, todo }

class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.body,
    required this.state,
    this.last = false,
  });
  final int n;
  final String title;
  final String body;
  final _StepState state;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final next = state == _StepState.next;
    final done = state == _StepState.done;
    final key = Container(
      width: 40,
      height: 48,
      decoration: BoxDecoration(
        color: WtColors.plum2,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: next ? WtColors.pink : WtColors.line,
          width: 2,
        ),
        boxShadow: next
            ? const [BoxShadow(color: Color(0x40FF5FAE), spreadRadius: 4)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          children: [
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: WtColors.grad),
              ),
            ),
            Center(
              child: done
                  ? const Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: WtColors.text,
                    )
                  : Text(
                      '$n',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: WtColors.text,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    return Opacity(
      opacity: done ? 0.55 : 1,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  key,
                  if (!last)
                    Expanded(child: Container(width: 2, color: WtColors.line)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 2, bottom: last ? 0 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: WtColors.text,
                            ),
                          ),
                        ),
                        if (state != _StepState.todo) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.fromLTRB(7, 1, 6, 1),
                            decoration: BoxDecoration(
                              color: next
                                  ? const Color(0x29FF5FAE)
                                  : const Color(0x14FFE8F8),
                              borderRadius: BorderRadius.circular(
                                WtRadius.pill,
                              ),
                            ),
                            child: Text(
                              done ? 'DONE' : 'NEXT',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.9,
                                color: next ? WtColors.pink : WtColors.tx3,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: WtColors.tx3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NameChip extends StatelessWidget {
  const _NameChip({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WtTap(
    onTap: onTap,
    radius: WtRadius.pill,
    tooltip: 'Change your name',
    semanticLabel: 'Joining as $name, change',
    child: Container(
      height: 44,
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.only(left: 6, right: 14),
      decoration: BoxDecoration(
        color: WtColors.plum,
        borderRadius: BorderRadius.circular(WtRadius.pill),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          WtAvatar(id: name, name: name, size: 30, ring: WtColors.plum),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                text: 'as ',
                children: [
                  TextSpan(
                    text: name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: WtColors.text,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: WtColors.tx3,
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.edit_outlined, size: 16, color: WtColors.tx3),
        ],
      ),
    ),
  );
}

/// Board `.found`: code, host and who is inside, what is playing, live state.
class _FoundCard extends StatelessWidget {
  const _FoundCard({
    required this.room,
    required this.state,
    required this.info,
    required this.copy,
  });
  final String room;
  final InviteState state;
  final RoomInfo? info;
  final LocalCopy? copy;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    const muted = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: WtColors.tx3,
    );
    final pill = switch (state) {
      InviteState.checking => const WtPill(
        label: 'Checking…',
        tone: WtTone.quiet,
        height: 28,
        fontSize: 13,
      ),
      InviteState.unchecked => const WtPill(
        label: "Couldn't check",
        tone: WtTone.quiet,
        height: 28,
        fontSize: 13,
      ),
      _ when (info?.memberCount ?? 0) > 0 => const WtPill(
        label: 'Live now',
        tone: WtTone.live,
        dot: WtDotStyle.pulse,
        height: 28,
        fontSize: 13,
      ),
      _ => const WtPill(
        label: 'Nobody inside yet',
        tone: WtTone.quiet,
        height: 28,
        fontSize: 13,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WtColors.plum,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: WtColors.line, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: WtKeyCaps(code: room),
                ),
              ),
              const SizedBox(width: 12),
              pill,
            ],
          ),
          const SizedBox(height: 12),
          if (info == null)
            Text(
              state == InviteState.checking
                  ? 'Looking up the room…'
                  : "We couldn't reach the room list. You can still join.",
              style: muted,
            )
          else ...[
            Row(
              children: [
                WtAvatarStack(
                  people: [for (final n in info.memberNames) (n, n)],
                  extra: info.memberCount - info.memberNames.length,
                ),
                if (info.memberCount > 0) const SizedBox(width: 10),
                Expanded(child: _whoLine(info, muted)),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 2, thickness: 2, color: WtColors.line),
            const SizedBox(height: 10),
            _itemLine(info, muted),
          ],
        ],
      ),
    );
  }

  Widget _whoLine(RoomInfo info, TextStyle muted) {
    final host = info.hostName;
    final others = [
      for (final n in info.memberNames)
        if (n != host) n,
    ];
    final inside = others.isEmpty
        ? null
        : others.length <= 2
        ? '${others.join(' and ')} inside'
        : '${others.length} others inside';
    return Text.rich(
      TextSpan(
        children: [
          if (host != null) ...[
            TextSpan(
              text: host,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: WtColors.text,
              ),
            ),
            const TextSpan(text: ' is hosting'),
            if (inside != null) TextSpan(text: ' · $inside'),
          ] else
            TextSpan(
              text: info.memberCount == 0
                  ? 'Nobody inside yet'
                  : '${info.memberCount} inside',
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: muted,
    );
  }

  Widget _itemLine(RoomInfo info, TextStyle muted) {
    final ref = info.itemRef;
    if (ref == null) {
      return Row(
        children: [
          const WtFileGlyph(size: 20),
          const SizedBox(width: 8),
          Text('Nothing playing yet', style: muted),
        ],
      );
    }
    final mine = copy != null && copy!.itemRef == ref ? copy : null;
    final position = info.positionMs;
    final details = [
      if (mine?.duration case final d? when d > Duration.zero)
        fmtTime(d.inMilliseconds),
      if (position != null)
        info.paused == false
            ? 'playing at ${fmtTime(position)}'
            : 'paused at ${fmtTime(position)}',
    ];
    return Row(
      children: [
        const WtFileGlyph(size: 20, color: WtColors.pink),
        const SizedBox(width: 8),
        Flexible(
          child: mine == null
              ? Text(
                  "Host's file",
                  maxLines: 1,
                  style: muted.copyWith(
                    fontWeight: FontWeight.w800,
                    color: WtColors.text,
                  ),
                )
              : WtMidText(
                  mine.name,
                  style: muted.copyWith(
                    fontWeight: FontWeight.w800,
                    color: WtColors.text,
                  ),
                ),
        ),
        if (details.isNotEmpty)
          Text(' · ${details.join(' · ')}', maxLines: 1, style: muted),
      ],
    );
  }
}

/// Board `.mine`: the local copy and whether it matches what the room plays.
class _MineRow extends StatelessWidget {
  const _MineRow({required this.copy, required this.hostRef, this.onChange});
  final LocalCopy copy;
  final String? hostRef;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final matches = hostRef != null && hostRef == copy.itemRef;
    final differs = hostRef != null && !matches;
    const strong = TextStyle(fontWeight: FontWeight.w800, color: WtColors.text);
    return WtDashed(
      color: WtColors.line,
      radius: WtRadius.control,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: [
            if (matches)
              const Icon(Icons.check_circle, size: 22, color: WtColors.cyan)
            else
              WtFileGlyph(
                size: 22,
                color: differs ? WtColors.yellow : WtColors.tx3,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: matches
                      ? [
                          const TextSpan(text: 'Your copy '),
                          const TextSpan(text: 'matches', style: strong),
                          TextSpan(text: ' · ${copy.details}'),
                        ]
                      : [
                          TextSpan(text: copy.name, style: strong),
                          TextSpan(
                            text: differs
                                ? ' · not the host\'s file'
                                : ' · ${copy.details}',
                          ),
                        ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: differs ? WtColors.yellow : WtColors.tx3,
                ),
              ),
            ),
            WtTextButton(label: 'Change', compact: true, onPressed: onChange),
          ],
        ),
      ),
    );
  }
}

class _CalmLine extends StatelessWidget {
  const _CalmLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  static const _style = TextStyle(
    fontSize: 13,
    height: 1.45,
    fontWeight: FontWeight.w600,
    color: WtColors.tx3,
  );

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Centred on the first line box, however many lines the text wraps to.
      SizedBox(
        height: _style.fontSize! * _style.height!,
        child: Center(child: Icon(icon, size: 18, color: WtColors.tx3)),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: _style)),
    ],
  );
}

/// A small single-field dialog (server URL, display name).
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String initial,
  required String hint,
  required IconData icon,
  required String? Function(String?) validate,
}) => showDialog<String>(
  context: context,
  barrierColor: const Color(0x8C000000),
  builder: (_) => _PromptDialog(
    title: title,
    initial: initial,
    hint: hint,
    icon: icon,
    validate: validate,
  ),
);

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.icon,
    required this.validate,
  });
  final String title;
  final String initial;
  final String hint;
  final IconData icon;
  final String? Function(String?) validate;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _draft = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _save() {
    final problem = widget.validate(_draft.text);
    if (problem != null) {
      setState(() => _error = problem);
    } else {
      Navigator.of(context).pop(_draft.text.trim());
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
      width: 440,
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
                    widget.title,
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
            const SizedBox(height: 16),
            WtField(
              controller: _draft,
              hint: widget.hint,
              icon: widget.icon,
              autofocus: true,
              height: 56,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: WtColors.yellow,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: WtButton(label: 'Save', onPressed: _save),
            ),
          ],
        ),
      ),
    ),
  );
}
