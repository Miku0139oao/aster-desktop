import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/main.dart';
import 'package:aster_desktop/pages.dart';

class FakeBackend implements DesktopBackend {
  final calls = <String>[];
  final changes = StreamController<Json>.broadcast();
  Json settings = const AppSettings(language: 'en', theme: 'light').toJson();
  final profiles = <Json>[];
  bool running = false;
  bool failImport = false;
  Json proxyData = {};
  @override
  Stream<Json> get events => changes.stream;
  @override
  Future<dynamic> call(String method, [Json? params]) async {
    calls.add(method);
    switch (method) {
      case 'state':
        return {
          'state': {
            'settings': settings,
            'profiles': profiles,
            'activeId': profiles.isEmpty ? '' : profiles.first['id'],
          },
          'core': {'running': running},
          'service': {'installed': false},
        };
      case 'import':
        if (failImport) {
          throw const BackendException('subscription unavailable');
        }
        profiles.add({
          'id': 'fixture',
          'name': 'My subscription',
          'content': 'proxies: []\nrules: [MATCH,DIRECT]\n',
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
      case 'controller':
        if (params!['path'] == '/proxies') {
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
  testWidgets('six pages fit the minimum supported window', (tester) async {
    final backend = FakeBackend();
    final c = await setup(tester, backend, size: const Size(760, 580));
    for (var i = 0; i < 6; i++) {
      c.navigate(i);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'page $i overflowed');
    }
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
      matchesGoldenFile('../evidence/overview-light.png'),
    );
    backend.settings = {...backend.settings, 'theme': 'dark'};
    await c.refresh();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AsterApp),
      matchesGoldenFile('../evidence/overview-dark.png'),
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
      matchesGoldenFile('../evidence/overview-zh.png'),
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
  test('export redacts common credentials', () {
    final result = sanitizeLogs(
      'anytls://password@example.com:443 Bearer super-secret password=foo',
    );
    expect(result, isNot(contains('super-secret')));
    expect(result, isNot(contains('password@example')));
    expect(result, isNot(contains('password=foo')));
  });
}
