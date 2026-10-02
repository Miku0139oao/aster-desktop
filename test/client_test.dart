import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/main.dart';
import 'package:aster_desktop/pages.dart';

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
  final profiles = <Json>[];
  bool running = false;
  bool failImport = false;
  String? coreError;
  Completer<dynamic>? pendingState;
  Json proxyData = {};
  Json connectionData = {'connections': []};
  final closedConnections = <String>[];
  final selections = <String, String>{};
  @override
  Stream<Json> get events => changes.stream;
  @override
  Future<dynamic> call(String method, [Json? params]) async {
    calls.add(method);
    switch (method) {
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
          'service': {'installed': false},
        };
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
