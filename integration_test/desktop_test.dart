import 'dart:io';
import 'dart:async';

import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/main.dart';
import 'package:aster_desktop/dialogs.dart';
import 'package:aster_desktop/application_rules.dart';
import 'package:re_editor/re_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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
      'proxies: [{name: Local A, type: direct}, {name: Local B, type: direct}]\n',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    for (var attempt = 0; attempt < 150 && c.profiles.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.profiles.length, 1, reason: c.error);
    c.navigate(1);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Local B'));
    await tester.pumpAndSettle();
    expect(c.selections['Proxy'], 'Local B');
    expect(c.running, isFalse);
    c.navigate(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primary-connect')));
    for (var attempt = 0; attempt < 150 && !c.running; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.running, isTrue, reason: c.error);
    expect((await c.api('GET', '/proxies/Proxy') as Json)['now'], 'Local B');
    expect(await c.saveSettings({'mode': 'global'}), isTrue, reason: c.error);
    expect((await c.api('GET', '/proxies/GLOBAL') as Json)['now'], 'Proxy');
    expect(c.currentNode, 'Local B');
    expect(await c.saveSettings({'mode': 'rule'}), isTrue, reason: c.error);
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
    // Select the real desktop executable from OS enumeration, then freely
    // switch its route through the GUI. No manually entered process identifier.
    unawaited(showApplicationRouting(tester.element(find.byType(Scaffold)), c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增應用程式'));
    await tester.pumpAndSettle();
    final executableName = Platform.resolvedExecutable
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');
    await tester.enterText(find.byType(TextField), executableName);
    await tester.tap(find.byKey(const ValueKey('application-filter-all')));
    await tester.pumpAndSettle();
    final application = find.byWidgetPredicate(
      (widget) =>
          widget is ListTile &&
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith('application:') &&
          (widget.key as ValueKey<String>).value
                  .split(RegExp(r'[/\\]'))
                  .last
                  .replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '') ==
              executableName,
    );
    await tester.tap(application.first);
    await tester.pumpAndSettle();
    // Different native font metrics can put a later route below the viewport.
    // Follow the user search flow before tapping rather than an offscreen row.
    await tester.enterText(find.byKey(const Key('route-search')), 'Local A');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('target:Local A')));
    await tester.tap(find.byKey(const ValueKey('target:Local A')));
    for (
      var attempt = 0;
      attempt < 150 && (c.active!.json['desktopRules'] as List? ?? []).isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(
      (c.active!.json['desktopRules'] as List).single.toString().endsWith(
        ',Local A',
      ),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('application-route-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('route-search')), 'DIRECT');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('target:DIRECT')));
    for (
      var attempt = 0;
      attempt < 150 &&
          !(c.active!.json['desktopRules'] as List).single.toString().endsWith(
            ',DIRECT',
          );
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(
      (c.active!.json['desktopRules'] as List).single.toString().endsWith(
        ',DIRECT',
      ),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('remove-application-rule-0')));
    for (
      var attempt = 0;
      attempt < 150 &&
          (c.active!.json['desktopRules'] as List? ?? []).isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(c.active!.json['desktopRules'] as List? ?? [], isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Edit a large document in the real desktop window while the core runs.
    unawaited(
      showYamlEditor(tester.element(find.byType(Scaffold)), c, c.active!),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<CodeEditor>(find.byKey(const Key('yaml-editor')))
        .controller!;
    editor.text =
        '${editor.text}\n${List.generate(10000, (i) => '# YAML 設定 $i').join('\n')}';
    editor.selection = const CodeLineSelection.collapsed(index: 100, offset: 0);
    await tester.pumpAndSettle();
    final before = editor.text;
    for (var i = 0; i < 30; i++) {
      editor.replaceSelection('#');
      await tester.pump();
    }
    final draft = editor.text;
    await c.poll();
    await tester.pump();
    expect(
      editor.text == draft,
      isTrue,
      reason: 'poll replaced the YAML draft',
    );
    editor.undo();
    await tester.pump();
    expect(editor.text == draft, isFalse);
    editor.text =
        before; // Keep the fixture configuration valid for real validation.
    await tester.tap(find.text('儲存並套用'));
    for (
      var attempt = 0;
      attempt < 150 &&
          find.byKey(const Key('yaml-editor')).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('yaml-editor')), findsNothing);
    expect(c.running, isTrue, reason: c.error);
    expect(c.active!.content == before, isTrue);
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
    binding.reportData = {'desktopWorkflowCompleted': true};
  });
}
