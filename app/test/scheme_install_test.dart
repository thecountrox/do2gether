import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/scheme_install.dart';

void main() {
  test('linux writes a desktop entry that claims both schemes', () async {
    final dir = await Directory.systemTemp.createTemp('scheme-test');
    addTearDown(() => dir.delete(recursive: true));
    final calls = <String>[];

    final installer = SchemeInstaller(
      executable: '/opt/do2gether/do2gether',
      home: dir.path,
      linux: true,
      windows: false,
      run: (cmd, args) async {
        calls.add('$cmd ${args.join(' ')}');
        return ProcessResult(0, 0, '', '');
      },
    );

    final path = await installer.install();

    expect(path, '${dir.path}/.local/share/applications/do2gether.desktop');
    final text = await File(path!).readAsString();
    expect(text, contains('Exec=/opt/do2gether/do2gether %u'));
    expect(text, contains('x-scheme-handler/do2gether;'));
    expect(text, contains('x-scheme-handler/watchtogether;'));
    expect(calls.any((c) => c.startsWith('xdg-mime default do2gether.desktop')), isTrue);
    expect(calls.where((c) => c.startsWith('xdg-mime')).length, 2);
  });

  test('windows registers HKCU classes for both schemes', () async {
    final calls = <String>[];
    final installer = SchemeInstaller(
      executable: r'C:\Program Files\do2gether\do2gether.exe',
      home: 'C:/Users/test',
      linux: false,
      windows: true,
      run: (cmd, args) async {
        calls.add('$cmd ${args.join(' ')}');
        return ProcessResult(0, 0, '', '');
      },
    );

    await installer.install();

    expect(calls.length, 6);
    expect(
      calls.any(
        (c) => c.contains(r'HKCU\Software\Classes\do2gether\shell\open\command') &&
            c.contains(r'"C:\Program Files\do2gether\do2gether.exe" "%1"'),
      ),
      isTrue,
    );
    expect(calls.where((c) => c.contains('URL Protocol')).length, 2);
  });

  test('a failing helper never throws', () async {
    final installer = SchemeInstaller(
      executable: '/x/do2gether',
      home: '/tmp/nope',
      linux: true,
      windows: false,
      run: (_, _) async => throw const ProcessException('xdg-mime', []),
    );
    expect(installer.install(), throwsA(isA<ProcessException>()));
  });
}
