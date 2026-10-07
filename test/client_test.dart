import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/main.dart';
import 'package:aster_desktop/pages.dart';
import 'package:aster_desktop/dialogs.dart';
import 'package:re_editor/re_editor.dart';
import 'package:yaml/yaml.dart';
import 'package:aster_desktop/application_rules.dart';
import 'package:aster_desktop/network_settings.dart';

String goldenPath(String name) {
  final platform = Platform.isWindows
      ? ''
      : '${Platform.operatingSystem}-${Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64'}/';
  return '../evidence/$platform$name.png';
}

class FakeBackend implements DesktopBackend {
  final calls = <String>[];
  final changes = StreamController<Json>.broadcast();
  Json settings = const AppSettings(language: 'en', theme: 'light').toJson();
  List<Json> networkInterfaces = [
    {'name': 'Wi-Fi'},
    {'name': 'Ethernet'},
  ];
  String desktopVersion = '0.1.0'; // Stable version in the visual fixtures.
  bool serviceInstalled = false;
  Completer<dynamic>? pendingValidation;
  String? validatedContent;
  Json? appliedPatch;
  final applications = <Json>[
    {
      'name': 'Browser',
      'path': r'C:\Program Files\Browser\browser.exe',
      'installed': true,
      'running': true,
      'background': false,
    },
  ];
  final profiles = <Json>[];
  bool running = false;
  bool failImport = false;
  String? coreError;
  Completer<dynamic>? pendingState;
  Json proxyData = {};
  Json providerData = {};
  Json connectionData = {'connections': []};
  final closedConnections = <String>[];
  final selections = <String, String>{};
  @override
  Stream<Json> get events => changes.stream;
  @override
  Future<dynamic> call(String method, [Json? params]) async {
    calls.add(method);
    switch (method) {
      case 'listNetworkInterfaces':
        return networkInterfaces;
      case 'state':
        if (pendingState != null) return pendingState!.future;
        return {
          'state': {
            'settings': settings,
            'profiles': profiles,
            'activeId': profiles.isEmpty ? '' : profiles.first['id'],
            'selections': selections,
          },
          'core': {
            'running': running,
            if (coreError != null) 'error': coreError,
          },
          'service': {'installed': serviceInstalled},
          'desktopVersion': desktopVersion,
        };
      case 'validate':
        validatedContent = params!['content'] as String;
        if (pendingValidation != null) return pendingValidation!.future;
        return true;
      case 'edit':
        profiles.first['content'] = params!['content'];
        return profiles.first;
      case 'restore':
        return profiles.first;
      case 'patchProfile':
        appliedPatch = params;
        final doc = Map<String, dynamic>.from(
          loadYaml(profiles.first['content'] as String) as Map,
        );
        doc.addAll(Map<String, dynamic>.from(params?['changes'] as Map? ?? {}));
        final rules = (doc['rules'] as List? ?? []).toList();
        if (params?['removeRule'] != null) {
          rules.removeWhere((e) => e == params!['removeRule']);
        }
        if (params?['rule'] != null) rules.insert(0, params!['rule']);
        doc['rules'] = rules;
        profiles.first['content'] = jsonEncode(doc);
        return profiles.first;
      case 'listApplications':
        return applications;
      case 'import':
        if (failImport) {
          throw const BackendException('subscription unavailable');
        }
        profiles.add({
          'id': 'fixture',
          'name': 'My subscription',
          'content': 'proxies: []\nrules: ["MATCH,DIRECT"]\n',
          'updated': '2026-10-02T00:00:00Z',
        });
        return profiles.last;
      case 'connect':
        running = true;
        return null;
      case 'disconnect':
        running = false;
        return null;
      case 'settings':
        settings = params!;
        return settings;
      case 'rememberSelection':
        selections[params!['group'] as String] = params['name'] as String;
        return true;
      case 'controller':
        if (params!['method'] == 'DELETE' &&
            (params['path'] as String).startsWith('/connections/')) {
          final id = Uri.decodeComponent(
            (params['path'] as String).substring('/connections/'.length),
          );
          closedConnections.add(id);
          (connectionData['connections'] as List).removeWhere(
            (dynamic entry) => (entry as Json)['id'] == id,
          );
          return null;
        }
        if (params['path'] == '/connections') return connectionData;
        if (params['method'] == 'PUT' &&
            (params['path'] as String).startsWith('/proxies/')) {
          final group = Uri.decodeComponent(
            (params['path'] as String).substring('/proxies/'.length),
          );
          final node = (params['body'] as Json)['name'] as String;
          (proxyData[group] as Json?)?['now'] = node;
          selections[group] = node;
          return null;
        }
        if (params['path'] == '/proxies') {
          return {'proxies': proxyData};
        }
        if (params['path'] == '/providers/proxies') {
          return {'providers': providerData};
        }
        if (params['path'] == '/version') return {'version': 'test-core'};
        return {'connections': [], 'rules': []};
      case 'logs':
        return <String>[];
      default:
        return null;
    }
  }

  @override
  Future<void> close() async {
    running = false;
    await changes.close();
  }
}

Future<AppController> setup(
  WidgetTester tester,
  FakeBackend backend, {
  Size size = const Size(1180, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = AppController(backend);
  addTearDown(c.dispose);
  await c.refresh();
  c.ready = true;
  await tester.pumpWidget(AsterApp(controller: c, desktopLifecycle: false));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets(
    'TUN network choice persists, locks while running and retains unavailable selection',
    (tester) async {
      final backend = FakeBackend();
      final c = AppController(backend);
      addTearDown(c.dispose);
      await c.refresh();
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 650,
              child: TunNetworkSelector(controller: c),
            ),
          ),
        ),
      );
      await mount();
      await tester.pumpAndSettle();
      expect(
        backend.calls.where((e) => e == 'listNetworkInterfaces').length,
        1,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wi-Fi').last);
      await tester.pumpAndSettle();
      expect(backend.settings['tunInterface'], 'Wi-Fi');
      expect(c.settings.tunInterface, 'Wi-Fi');
      expect(backend.settings['tun'], false);
      c.running = true;
      await mount();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged,
        isNull,
      );
      expect(
        backend.calls.where((e) => e == 'listNetworkInterfaces').length,
        1,
      );
      c.running = false;
      backend.networkInterfaces = [
        {'name': 'Ethernet'},
      ];
      await tester.tap(find.byTooltip('Refresh networks'));
      await tester.pumpAndSettle();
      expect(find.text('Wi-Fi (unavailable)'), findsOneWidget);
      expect(c.settings.tunInterface, 'Wi-Fi');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic (system routes)').last);
      await tester.pumpAndSettle();
      expect(backend.settings['tunInterface'], '');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'app chooser separates apps from helpers and selects an offline installed app by keyboard',
    (tester) async {
      final backend = FakeBackend();
      if (const bool.fromEnvironment('ASTER_CAPTURE_APPLICATION_PICKER')) {
        final font = FontLoader('NotoSansTC')
          ..addFont(rootBundle.load('assets/NotoSansTC.ttf'));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      }
      backend.applications.addAll([
        {
          'name': 'Photo Studio',
          'path': r'C:\Apps\Photo Studio\photo.exe',
          'installed': true,
          'running': false,
          'background': false,
        },
        {
          'name': 'Network Helper',
          'path': r'C:\Apps\helper.exe',
          'installed': false,
          'running': true,
          'background': true,
        },
      ]);
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content': 'proxies: []\nrules: [MATCH,DIRECT]\n',
      });
      final c = await setup(tester, backend, size: const Size(900, 640));
      unawaited(
        showApplicationRouting(tester.element(find.byType(Scaffold)), c),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add application'));
      await tester.pumpAndSettle();
      expect(find.text('Photo Studio'), findsOneWidget);
      expect(find.text('Network Helper'), findsNothing);
      if (const bool.fromEnvironment('ASTER_CAPTURE_APPLICATION_PICKER')) {
        await expectLater(
          find.byType(AsterApp),
          matchesGoldenFile('../.build/application-picker-preview.png'),
        );
      }
      expect(find.text(r'C:\Apps\Photo Studio\photo.exe'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('application-filter-running')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Photo Studio'), findsNothing);
      expect(find.text('Network Helper'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('application-filter-apps')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(
            const ValueKey(r'application:C:\Apps\Photo Studio\photo.exe'),
          ),
          matching: find.byTooltip('Application details'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'C:\Apps\Photo Studio\photo.exe'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('application-search')),
        'Photo Studio',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('target:DIRECT')));
      await tester.pumpAndSettle();
      expect(
        backend.appliedPatch!['rule'],
        r'PROCESS-PATH,C:\Apps\Photo Studio\photo.exe,DIRECT',
      );
      expect(find.text('Photo Studio'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'large app catalog searches exact identities without mixing same-name applications',
    (tester) async {
      final backend = FakeBackend();
      backend.applications.addAll(
        List.generate(
          2500,
          (i) => {
            'name': 'Application $i',
            'path': 'C:\\Apps\\$i\\app.exe',
            'installed': true,
            'running': false,
            'background': false,
          },
        ),
      );
      backend.applications.addAll([
        {
          'name': 'Twin App',
          'path': r'C:\Apps\first\app.exe',
          'installed': true,
        },
        {
          'name': 'Twin App',
          'path': r'C:\Apps\second\app.exe',
          'installed': true,
        },
      ]);
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content': 'proxies: []\nrules: [MATCH,DIRECT]\n',
      });
      final c = await setup(tester, backend);
      unawaited(
        showApplicationRouting(tester.element(find.byType(Scaffold)), c),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add application'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(40));
      await tester.enterText(
        find.byKey(const Key('application-search')),
        'Twin App',
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Twin App'), findsNWidgets(2));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route-search')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('application-search')),
        r'C:\Apps\second',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey(r'application:C:\Apps\second\app.exe')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('target:REJECT')));
      await tester.pumpAndSettle();
      expect(
        backend.appliedPatch!['rule'],
        r'PROCESS-PATH,C:\Apps\second\app.exe,REJECT',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'node browser hides managed application groups and GLOBAL members',
    (tester) async {
      final backend = FakeBackend()..running = true;
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content':
            "proxies: [{name: Tokyo, type: direct}]\nrules: ['MATCH,DIRECT']\n",
        'desktopProviderRoutes': [
          {
            'group': 'Aster-App-private',
            'provider': 'Subscription',
            'node': 'Tokyo',
          },
        ],
      });
      backend.proxyData = {
        'GLOBAL': {
          'type': 'Selector',
          'all': ['Tokyo', 'Aster-App-private'],
          'now': 'Tokyo',
        },
        'Aster-App-private': {
          'type': 'Selector',
          'all': ['Tokyo'],
          'now': 'Tokyo',
        },
        'Tokyo': {'type': 'Direct'},
      };
      final c = await setup(tester, backend);
      await c.loadRuntime();
      c.navigate(1);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Tokyo'), findsOneWidget);
      expect(find.text('Aster-App-private'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'application routes freely choose and search a large node catalog',
    (tester) async {
      final backend = FakeBackend();
      const app = r'C:\Program Files\Browser\browser.exe';
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content': jsonEncode({
          'proxies': List.generate(
            3000,
            (i) => {
              'name': 'Node-$i',
              'type': 'socks5',
              'server': '127.0.0.1',
              'port': 1000 + i,
            },
          ),
          'proxy-groups': [
            {
              'name': 'Proxy',
              'type': 'select',
              'proxies': ['DIRECT'],
            },
          ],
          'rules': ['PROCESS-PATH,$app,DIRECT', 'MATCH,Proxy'],
        }),
      });
      final c = await setup(tester, backend);
      unawaited(
        showApplicationRouting(tester.element(find.byType(Scaffold)), c),
      );
      await tester.pumpAndSettle();
      var previous = 'DIRECT';
      for (final target in ['Node-2999', 'REJECT', 'Proxy', 'DIRECT']) {
        await tester.tap(find.byKey(const ValueKey('application-route-0')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('route-search')), target);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('target:$target')));
        await tester.pumpAndSettle();
        expect(backend.appliedPatch, {
          'id': 'apps',
          'rule': 'PROCESS-PATH,$app,$target',
          'removeRule': 'PROCESS-PATH,$app,$previous',
        });
        expect(c.profileDocument!['rules'], [
          'PROCESS-PATH,$app,$target',
          'MATCH,Proxy',
        ]);
        previous = target;
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'provider node selection sends independent typed application route',
    (tester) async {
      final backend = FakeBackend()..running = true;
      const rule = r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,DIRECT';
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content': jsonEncode({
          'proxy-providers': {
            'Subscription': {
              'type': 'http',
              'url': 'https://example.com/nodes',
            },
          },
          'proxy-groups': [
            {
              'name': 'Proxy',
              'type': 'select',
              'use': ['Subscription'],
            },
          ],
          'rules': [rule, 'MATCH,Proxy'],
        }),
      });
      backend.providerData = {
        'Subscription': {
          'proxies': [
            {'name': 'Tokyo', 'type': 'VLESS'},
          ],
        },
      };
      final c = await setup(tester, backend);
      unawaited(
        showApplicationRouting(tester.element(find.byType(Scaffold)), c),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('application-route-0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('route-search')), 'Tokyo');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('provider:Subscription:Tokyo')),
      );
      await tester.pumpAndSettle();
      expect(backend.appliedPatch, {
        'id': 'apps',
        'removeRule': rule,
        'providerRoute': {
          'kind': 'PROCESS-PATH',
          'match': r'C:\Program Files\Browser\browser.exe',
          'provider': 'Subscription',
          'node': 'Tokyo',
        },
      });
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'application manager selects a running app without process input',
    (tester) async {
      final backend = FakeBackend();
      backend.profiles.add({
        'id': 'apps',
        'name': 'Apps',
        'content': "proxies: []\nproxy-groups: [{name: Proxy, type: select, proxies: [DIRECT]}]\nrules: ['MATCH,Proxy']\n",
      });
      final c = await setup(tester, backend, size: const Size(900, 640));
      unawaited(
        showApplicationRouting(tester.element(find.byType(Scaffold)), c),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add application'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('listApplications'));
      await tester.enterText(find.byType(TextField), 'browser');
      await tester.tap(find.text('Browser'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route-search')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('target:Proxy')));
      await tester.pumpAndSettle();
      expect(backend.appliedPatch, {
        'id': 'apps',
        'rule': r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,Proxy',
      });
      expect(find.text('Browser'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('application manager changes and removes the route in GUI', (
    tester,
  ) async {
    final backend = FakeBackend();
    const rule = r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,DIRECT';
    backend.profiles.add({
      'id': 'apps',
      'name': 'Apps',
      'content': jsonEncode({
        'proxies': [],
        'proxy-groups': [
          {
            'name': 'Proxy',
            'type': 'select',
            'proxies': ['DIRECT'],
          },
        ],
        'rules': [rule, 'MATCH,Proxy'],
      }),
    });
    final c = await setup(tester, backend);
    unawaited(showApplicationRouting(tester.element(find.byType(Scaffold)), c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('application-route-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('target:Proxy')));
    await tester.pumpAndSettle();
    expect(backend.appliedPatch, {
      'id': 'apps',
      'rule': r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,Proxy',
      'removeRule': rule,
    });
    await tester.tap(find.byKey(const ValueKey('remove-application-rule-0')));
    await tester.pumpAndSettle();
    expect(backend.appliedPatch, {
      'id': 'apps',
      'removeRule': r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,Proxy',
    });
    expect(find.text('No application rules yet'), findsOneWidget);
    expect(c.profileDocument!['rules'], ['MATCH,Proxy']);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'application routing uses core process rules and enables lookup',
    (tester) async {
      final backend = FakeBackend();
      backend.profiles.add({
        'id': 'apps',
        'name': 'Applications',
        'content': 'proxies: []\nproxy-groups: [{name: Proxy, type: select, proxies: [DIRECT]}]\nfind-process-mode: off\nrules: [MATCH,DIRECT]\n',
      });
      final c = await setup(tester, backend, size: const Size(900, 620));
      unawaited(
        showRuleDialog(
          tester.element(find.byType(Scaffold)),
          c,
          application: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose application'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'browser.exe');
      await tester.ensureVisible(find.text('Add and apply'));
      await tester.tap(find.text('Add and apply'));
      await tester.pumpAndSettle();
      expect(backend.appliedPatch, {
        'id': 'apps',
        'rule': 'PROCESS-NAME,browser.exe,Proxy',
        'changes': {'find-process-mode': 'strict'},
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'application path routing preserves spaces and rejects rule delimiters',
    (tester) async {
      final backend = FakeBackend();
      backend.profiles.add({
        'id': 'apps',
        'name': 'Applications',
        'content': 'proxies: []\nrules: [MATCH,DIRECT]\n',
      });
      final c = await setup(tester, backend);
      unawaited(
        showRuleDialog(
          tester.element(find.byType(Scaffold)),
          c,
          application: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Application name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Application executable path').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bad,rule');
      await tester.tap(find.text('Add and apply'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid match.'), findsOneWidget);
      expect(backend.appliedPatch, isNull);
      await tester.enterText(
        find.byType(TextField),
        r'C:\Program Files\Browser\browser.exe',
      );
      await tester.tap(find.text('Add and apply'));
      await tester.pumpAndSettle();
      expect(
        backend.appliedPatch!['rule'],
        r'PROCESS-PATH,C:\Program Files\Browser\browser.exe,DIRECT',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large YAML edits survive polling, validation, undo and save', (
    tester,
  ) async {
    final backend = FakeBackend();
    final content =
        '${List.generate(10000, (i) => '# 設定 $i · https://example.test/a-long-path/$i').join('\n')}\nproxies: []\nrules: ["MATCH,DIRECT"]\n';
    backend.profiles.add({
      'id': 'large',
      'name': 'Large YAML',
      'content': content,
    });
    final c = await setup(tester, backend);
    unawaited(
      showYamlEditor(tester.element(find.byType(Scaffold)), c, c.active!),
    );
    await tester.pumpAndSettle();
    final widget = tester.widget<CodeEditor>(
      find.byKey(const Key('yaml-editor')),
    );
    final editor = widget.controller!;
    final lastLine = editor.codeLines.length - 1;
    editor.selection = CodeLineSelection.collapsed(index: lastLine, offset: 0);
    editor.replaceSelection('# user draft');
    final draft = editor.text;
    editor.undo();
    expect(editor.text, content);
    editor.redo();
    expect(editor.text, draft);
    await tester.pump();
    // Exercise the desktop text input channel, including a Chinese IME commit.
    final input = tester.testTextInput.editingState!['text'] as String;
    final offset = tester.testTextInput.editingState!['selectionExtent'] as int;
    final client =
        (tester.testTextInput.log
                    .lastWhere((call) => call.method == 'TextInput.setClient')
                    .arguments
                as List)
            .first;
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
          {
            'deltas': [
              {
                'oldText': input,
                'deltaText': ' · 中文',
                'deltaStart': offset,
                'deltaEnd': offset,
                'selectionBase': offset + 5,
                'selectionExtent': offset + 5,
                'selectionAffinity': 'TextAffinity.downstream',
                'selectionIsDirectional': false,
                'composingBase': -1,
                'composingExtent': -1,
              },
            ],
          },
        ]),
      ),
      (_) {},
    );
    await tester.pump();
    expect(editor.text.endsWith('# user draft · 中文'), isTrue);
    final edited = editor.text;
    for (var i = 0; i < 5; i++) {
      await c.poll();
      backend.changes.add({
        'event': 'traffic',
        'data': {'up': i, 'down': i},
      });
      await tester.pump();
    }
    expect(editor.text, edited);
    expect(backend.calls, isNot(contains('validate')));
    final validation = Completer<dynamic>();
    backend.pendingValidation = validation;
    await tester.tap(find.text('Validate'));
    await tester.pump();
    expect(
      tester.widget<CodeEditor>(find.byKey(const Key('yaml-editor'))).readOnly,
      isTrue,
    );
    expect(backend.validatedContent, edited);
    validation.complete(true);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CodeEditor>(find.byKey(const Key('yaml-editor'))).readOnly,
      isFalse,
    );
    await tester.tap(find.text('Save and apply'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('yaml-editor')), findsNothing);
    expect(c.active!.content, edited);
    expect(tester.takeException(), isNull);
  });

  test('profile parsing is reused until the content changes', () async {
    final backend = FakeBackend();
    backend.profiles.add({
      'id': 'cache',
      'name': 'Cache',
      'content': 'rules: ["MATCH,First"]',
    });
    final c = AppController(backend);
    addTearDown(c.dispose);
    addTearDown(backend.close);
    await c.refresh();
    final parsed = c.profileDocument;
    await c.refresh();
    expect(identical(c.profileDocument, parsed), isTrue);
    expect(c.profileTarget, 'First');
    backend.profiles.first['content'] = 'rules: ["MATCH,Second"]';
    await c.refresh();
    expect(identical(c.profileDocument, parsed), isFalse);
    expect(c.profileTarget, 'Second');
  });

  testWidgets(
    'installed service and slow controller failures have accurate guidance',
    (tester) async {
      final backend = FakeBackend()
        ..serviceInstalled = true
        ..desktopVersion = '0.1.2';
      final c = await setup(tester, backend);
      expect(find.text('Aster Desktop 0.1.2'), findsOneWidget);
      c.reportError(
        'TUN adapter did not become ready; check the background service',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Install the background service'),
        findsNothing,
      );
      expect(find.textContaining('Try system proxy'), findsOneWidget);
      c.reportError(
        'core startup timed out while waiting for controller; remote providers may be unavailable',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('loading remote rules'), findsOneWidget);
    },
  );
  test(
    'poll preserves the core failure and retrieves logs while stopped',
    () async {
      final backend = FakeBackend()..running = true;
      final c = AppController(backend);
      addTearDown(c.dispose);
      addTearDown(backend.close);
      await c.refresh();
      c.ready = true;
      c.page = 4;
      backend.running = false;
      backend.coreError = 'TUN adapter could not start: permission denied';
      await c.poll();
      expect(c.running, isFalse);
      expect(c.error, backend.coreError);
      expect(backend.calls.last, 'logs');
    },
  );

  test('an old poll cannot overwrite a completed connection', () async {
    final backend = FakeBackend();
    final c = AppController(backend);
    addTearDown(c.dispose);
    addTearDown(backend.close);
    await c.refresh();
    c.ready = true;
    final oldState = {
      'state': {
        'settings': backend.settings,
        'profiles': <Json>[],
        'activeId': '',
        'selections': <String, String>{},
      },
      'core': {'running': false},
      'service': <String, dynamic>{},
    };
    final delayed = Completer<dynamic>();
    backend.pendingState = delayed;
    final poll = c.poll();
    backend.pendingState = null;
    expect(await c.toggle(), isTrue);
    expect(c.running, isTrue);
    delayed.complete(oldState);
    await poll;
    expect(c.running, isTrue);
    expect(c.error, isNull);
  });

  testWidgets('first use imports and connects without technical setup', (
    tester,
  ) async {
    final backend = FakeBackend();
    await setup(tester, backend);
    expect(find.text('Start with a subscription'), findsOneWidget);
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-source')),
      'https://example.com/subscription',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Ready to connect'), findsOneWidget);
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    expect(backend.calls, containsAllInOrder(['import', 'connect']));
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    expect(backend.running, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed import stays in dialog and keeps existing data', (
    tester,
  ) async {
    final backend = FakeBackend()..failImport = true;
    await setup(tester, backend);
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-source')),
      'https://example.com/subscription',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pumpAndSettle();
    expect(find.text('subscription unavailable'), findsOneWidget);
    expect(backend.profiles, isEmpty);
    expect(find.byKey(const Key('import-submit')), findsOneWidget);
  });
  testWidgets('node can be chosen before the first connection', (tester) async {
    final backend = FakeBackend();
    backend.profiles.add({
      'id': 'offline',
      'name': 'Offline selection',
      'content': 'proxies: [{name: First, type: direct}, {name: Second, type: direct}]\nproxy-groups: [{name: Choice, type: select, proxies: [First, Second]}]\nrules: ["MATCH,Choice"]\n',
    });
    final c = await setup(tester, backend);
    c.navigate(1);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Second'));
    await tester.pumpAndSettle();
    expect(c.running, isFalse);
    expect(c.selections['Choice'], 'Second');
    expect(backend.calls, contains('rememberSelection'));
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Second'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    c.navigate(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primary-connect')));
    await tester.pumpAndSettle();
    expect(backend.calls, containsAllInOrder(['rememberSelection', 'connect']));
    expect(c.running, isTrue);
  });
  testWidgets('six pages fit the minimum supported window', (tester) async {
    final backend = FakeBackend();
    final c = await setup(tester, backend, size: const Size(760, 580));
    for (var i = 0; i < 6; i++) {
      c.navigate(i);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'page $i overflowed');
    }
  });
  testWidgets('global mode continues using the chosen node', (tester) async {
    final backend = FakeBackend()..running = true;
    backend.profiles.add({
      'id': 'global',
      'name': 'Global selection',
      'content': 'proxy-groups: [{name: Choice, type: select, proxies: [First, Second]}]\nrules: ["MATCH,Choice"]\n',
    });
    backend.proxyData = {
      'GLOBAL': {
        'type': 'Selector',
        'all': ['DIRECT', 'Choice'],
        'now': 'DIRECT',
      },
      'Choice': {
        'type': 'Selector',
        'all': ['First', 'Second'],
        'now': 'First',
      },
    };
    final c = await setup(tester, backend);
    expect(await c.saveSettings({'mode': 'global'}), isTrue);
    expect((backend.proxyData['GLOBAL'] as Json)['now'], 'Choice');
    expect(c.currentNode, 'First');
    expect(await c.selectNode('Choice', 'Second'), isTrue);
    expect(c.currentNode, 'Second');
    expect(await c.saveSettings({'mode': 'direct'}), isTrue);
    expect(c.currentNode, 'DIRECT');
  });
  testWidgets('light and dark Material 3 overview renders', (tester) async {
    final backend = FakeBackend();
    final font = FontLoader('NotoSansTC');
    font.addFont(rootBundle.load('assets/NotoSansTC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final c = await setup(tester, backend);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AsterApp),
      matchesGoldenFile(goldenPath('overview-light')),
    );
    backend.settings = {...backend.settings, 'theme': 'dark'};
    await c.refresh();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AsterApp),
      matchesGoldenFile(goldenPath('overview-dark')),
    );
    backend.settings = {
      ...backend.settings,
      'theme': 'light',
      'language': 'zh_TW',
    };
    await c.refresh();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AsterApp),
      matchesGoldenFile(goldenPath('overview-zh')),
    );
  });
  testWidgets('large node collection can be searched at high text scaling', (
    tester,
  ) async {
    final backend = FakeBackend()..running = true;
    final names = List.generate(2000, (i) => 'Node $i');
    backend.proxyData = {
      'Proxy': {'type': 'Selector', 'all': names, 'now': names.first},
      for (final name in names) name: {'type': 'Shadowsocks', 'history': []},
    };
    final c = await setup(tester, backend, size: const Size(760, 580));
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    c.navigate(1);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await tester.enterText(find.byType(TextField), 'Node 1999');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Node 1999'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('large connection collection can be searched and closed', (
    tester,
  ) async {
    final backend = FakeBackend()..running = true;
    backend.connectionData = {
      'connections': List.generate(
        10000,
        (i) => {
          'id': 'connection-$i',
          'metadata': {
            'host': 'host-$i.example.test',
            'destinationPort': '443',
            'process': 'browser',
          },
          'chains': ['Proxy', 'Test node'],
          'rule': 'MATCH',
          'upload': 100,
          'download': 200,
        },
      ),
    };
    final c = await setup(tester, backend, size: const Size(760, 580));
    c.navigate(3);
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile).evaluate().length, lessThan(30));
    await tester.enterText(find.byType(TextField), 'host-9999.example.test');
    await tester.pumpAndSettle();
    expect(find.text('host-9999.example.test:443'), findsOneWidget);
    await tester.tap(find.byTooltip('Close connection'));
    await tester.pumpAndSettle();
    expect(backend.closedConnections, ['connection-9999']);
    expect((backend.connectionData['connections'] as List).length, 9999);
    expect(find.text('No active connections'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('export redacts common credentials', () {
    final result = sanitizeLogs(
      'anytls://password@example.com:443 Bearer super-secret password=foo',
    );
    expect(result, isNot(contains('super-secret')));
    expect(result, isNot(contains('password@example')));
    expect(result, isNot(contains('password=foo')));
  });
}
