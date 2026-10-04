import 'dart:io';

import 'package:aster_desktop/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mac app bundle and executable aliases resolve to the actual path', () async {
    final directory = await Directory.systemTemp.createTemp('aster-app-path-');
    addTearDown(() => directory.delete(recursive: true));
    final bundle = Directory('${directory.path}/Routing App.app');
    await Directory('${bundle.path}/Contents/MacOS').create(recursive: true);
    final executable = File('${bundle.path}/Contents/MacOS/Routing App');
    await executable.writeAsString('fixture');
    final plist = File('${bundle.path}/Contents/Info.plist');
    await plist.writeAsString(
      '<?xml version="1.0"?><plist version="1.0"><dict>'
      '<key>CFBundleExecutable</key><string>Routing App</string></dict></plist>',
    );
    final alias = Link('${directory.path}/Alias App.app');
    await alias.create(bundle.path);
    final actual = await executable.resolveSymbolicLinks();
    expect(await resolveApplicationExecutable(alias.path), actual);
    expect(await resolveApplicationExecutable(executable.path), actual);
    await plist.writeAsString(
      '<?xml version="1.0"?><plist version="1.0"><dict>'
      '<key>CFBundleExecutable</key><string>../outside</string></dict></plist>',
    );
    await expectLater(
      resolveApplicationExecutable(bundle.path),
      throwsFormatException,
    );
  }, skip: !Platform.isMacOS);
}
