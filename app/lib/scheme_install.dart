import 'dart:io';

/// Registers `do2gether://` (and the legacy `watchtogether://`) with the desktop so an invite link
/// opens this app.
///
/// Shipping a tarball or zip means there is no installer to do this, so the app does it itself on
/// first run. Everything is best-effort: a failure here must never stop the app from starting.
class SchemeInstaller {
  SchemeInstaller({
    required this.executable,
    required this.home,
    this.run = _run,
    bool? linux,
    bool? windows,
  }) : isLinux = linux ?? Platform.isLinux,
       isWindows = windows ?? Platform.isWindows;

  final String executable;
  final String home;
  final Future<ProcessResult> Function(String cmd, List<String> args) run;
  final bool isLinux;
  final bool isWindows;

  static const List<String> schemes = ['do2gether', 'watchtogether'];

  Future<String?> install() async {
    if (isLinux) return _installLinux();
    if (isWindows) return _installWindows();
    return null;
  }

  Future<String?> _installLinux() async {
    final dir = Directory('$home/.local/share/applications');
    await dir.create(recursive: true);
    final file = File('${dir.path}/do2gether.desktop');
    final mime = schemes.map((s) => 'x-scheme-handler/$s;').join();
    await file.writeAsString('''
[Desktop Entry]
Type=Application
Name=do2gether
Comment=Watch, listen and do things together
Exec=$executable %u
Icon=video-display
Terminal=false
Categories=AudioVideo;Player;Network;
MimeType=$mime
StartupWMClass=watch_together
''');
    await run('update-desktop-database', [dir.path]);
    for (final scheme in schemes) {
      await run('xdg-mime', ['default', 'do2gether.desktop', 'x-scheme-handler/$scheme']);
    }
    return file.path;
  }

  Future<String?> _installWindows() async {
    // HKCU so no elevation is needed. The URL is passed to the app as argv[1].
    for (final scheme in schemes) {
      final key = 'HKCU\\Software\\Classes\\$scheme';
      await run('reg', ['add', key, '/ve', '/d', 'URL:do2gether invite', '/f']);
      await run('reg', ['add', key, '/v', 'URL Protocol', '/d', '', '/f']);
      await run('reg', [
        'add',
        '$key\\shell\\open\\command',
        '/ve',
        '/d',
        '"$executable" "%1"',
        '/f',
      ]);
    }
    return 'HKCU\\Software\\Classes\\${schemes.first}';
  }
}

Future<ProcessResult> _run(String cmd, List<String> args) async {
  try {
    return await Process.run(cmd, args);
  } on Object {
    return ProcessResult(0, 1, '', '$cmd unavailable');
  }
}

/// Best-effort: install the scheme handler and report where it landed (or why it did not).
Future<String?> ensureInviteScheme({
  required String executable,
  required String home,
  Future<ProcessResult> Function(String, List<String>)? run,
}) async {
  final installer = SchemeInstaller(
    executable: executable,
    home: home,
    run: run ?? _run,
  );
  try {
    return await installer.install();
  } on Object catch (e) {
    stderr.writeln('invite scheme not registered: $e');
    return null;
  }
}
