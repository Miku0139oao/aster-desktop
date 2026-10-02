import 'dart:io';

import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native desktop imports, proxies HTTP and stops with real core', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1180, 800));
    await windowManager.show();
    final directory = await Directory.systemTemp.createTemp(
      'aster-desktop-integration-',
    );
    final backend = await ProcessBackend.start(dataDirectory: directory);
    final c = AppController(backend);
    addTearDown(() async {
      c.dispose();
      await backend.close();
      await directory.delete(recursive: true);
    });
    await backend.call(
      'settings',
      const AppSettings(
        systemProxy: false,
        mixedPort: 17891,
        theme: 'light',
      ).toJson(),
    );
    await c.refresh();
    c.ready = true;
    await tester.pumpWidget(
      AsterApp(controller: c, desktopLifecycle: Platform.isWindows),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('貼上內容'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-source')),
      'proxies: []\nrules:\n - MATCH,DIRECT\n',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    for (var attempt = 0; attempt < 150 && c.profiles.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.profiles.length, 1, reason: c.error);
    await tester.tap(find.byKey(const Key('primary-connect')));
    for (var attempt = 0; attempt < 150 && !c.running; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.running, isTrue, reason: c.error);
    if (Platform.isWindows) {
      await windowManager.close();
      await tester.pump(const Duration(seconds: 1));
      expect(await windowManager.isVisible(), isFalse);
      expect(
        c.running,
        isTrue,
        reason: 'closing to tray must retain the proxy',
      );
      await windowManager.show();
      addTearDown(() async {
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
      });
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('native-desktop-proxy');
      request.response.close();
    });
    final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:17891';
    addTearDown(() => http.close(force: true));
    final request = await http.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/native-test'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(
      await response.transform(const SystemEncoding().decoder).join(),
      'native-desktop-proxy',
    );
    for (var page = 0; page < 6; page++) {
      c.navigate(page);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'page $page');
    }
    c.navigate(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primary-connect')));
    for (var attempt = 0; attempt < 150 && c.running; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.running, isFalse, reason: c.error);
    final socket = await Socket.connect(
      '127.0.0.1',
      17891,
      timeout: const Duration(seconds: 1),
    ).then<Socket?>((s) => s, onError: (_) => null);
    expect(socket, isNull, reason: 'proxy port should close after stopping');
    socket?.destroy();
  });
}
