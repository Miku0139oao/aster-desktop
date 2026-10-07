import 'dart:convert';

import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'client_test.dart' as fixtures;

class WorkspaceBackend extends fixtures.FakeBackend {
  Json preferences = {};
  Json? mutation;
  final history = {
    'days': <Json>[
      {
        'date': DateTime.now().toIso8601String().split('T').first,
        'upload': 1024,
        'download': 2048,
        'applications': {
          'Browser': {'upload': 512, 'download': 1024},
        },
      },
    ],
  };
  @override
  Future<dynamic> call(String method, [Json? params]) async {
    switch (method) {
      case 'preferences':
        preferences = params!['preferences'] as Json;
        return true;
      case 'trafficHistory':
        return history;
      case 'diagnose':
        return <Json>[
          {
            'kind': 'core',
            'status': 'pass',
            'detail': 'Fixture core',
            'milliseconds': 0,
          },
          {
            'kind': 'systemRequest',
            'status': 'fail',
            'detail': 'Fixture route timeout',
            'milliseconds': 8000,
          },
        ];
      case 'manageObject':
        mutation = params;
        final doc = jsonDecode(
          jsonEncode(loadYaml(profiles.first['content'] as String)),
        ) as Json;
        (doc[params!['field']] as List).add(params['object']);
        profiles.first['content'] = jsonEncode(doc);
        return profiles.first;
      case 'batchApplicationRules':
        mutation = params;
        return true;
      case 'previewRefresh':
        return {
          'token': 'fixture-token',
          'added': ['proxies / New node'],
          'removed': [],
          'changed': ['rules'],
          'warnings': [],
        };
      case 'applyRefresh':
        mutation = params;
        return true;
    }
    final result = await super.call(method, params);
    if (method == 'state') {
      (result['state'] as Json)['preferences'] = preferences;
    }
    return result;
  }
}

WorkspaceBackend workspaceFixture() => WorkspaceBackend()
  ..profiles.add({
    'id': 'workspace',
    'name': 'Demo',
    'content': 'proxies: [{name: Node, type: http, server: 192.0.2.1, port: 8080}]\nproxy-groups: [{name: Choose, type: select, proxies: [Node,DIRECT]}]\nrules: [MATCH,Choose]\n',
  });

void main() {
  testWidgets(
    'favorite identity and display preferences survive controller refresh',
    (tester) async {
      final backend = workspaceFixture();
      final c = await fixtures.setup(tester, backend);
      c.navigate(1);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Favorite').first);
      await tester.pumpAndSettle();
      await c.refresh();
      await tester.pumpAndSettle();
      expect(c.isFavorite('Node'), true);
      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();
      expect(find.text('Node'), findsWidgets);
      await c.toggleFavorite('Node', provider: 'Remote');
      await c.refresh();
      expect(c.isFavorite('Node', provider: 'Remote'), true);
      await c.toggleFavorite('Node');
      await c.refresh();
      expect(c.isFavorite('Node'), false);
      expect(c.isFavorite('Node', provider: 'Remote'), true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('typed node editor copies and saves without a YAML editor', (
    tester,
  ) async {
    final backend = workspaceFixture();
    final c = await fixtures.setup(tester, backend);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ObjectEditor(
            c: c,
            field: 'proxies',
            initial: {
              'name': 'Node',
              'type': 'http',
              'server': '192.0.2.2',
              'port': 8080,
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Node (copy)'), findsOneWidget);
    await tester.tap(find.text('Validate and save'));
    await tester.pumpAndSettle();
    expect(backend.mutation!['action'], 'create');
    expect(backend.mutation!['object']['name'], 'Node (copy)');
    expect(backend.mutation!['object']['port'], 8080);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'application page selects multiple programs and applies one route',
    (tester) async {
      final backend = workspaceFixture();
      backend.applications.add({
        'name': 'Editor',
        'path': r'C:\Apps\editor.exe',
        'installed': true,
        'running': false,
        'background': false,
      });
      final c = await fixtures.setup(tester, backend);
      c.navigate(6);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select multiple apps for one route'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey(r'application:C:\Program Files\Browser\browser.exe'),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey(r'application:C:\Apps\editor.exe')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('target:DIRECT')));
      await tester.pumpAndSettle();
      expect(backend.mutation!['target'], 'DIRECT');
      expect((backend.mutation!['paths'] as List).length, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connection details create an application rule with an explicit route',
    (tester) async {
      final backend = workspaceFixture()..running = true;
      backend.connectionData = {
        'connections': [
          {
            'id': 'one',
            'metadata': {
              'host': 'example.com',
              'network': 'tcp',
              'process': 'browser.exe',
              'processPath': r'C:\Apps\browser.exe',
            },
            'chains': ['DIRECT'],
            'upload': 0,
            'download': 1,
          },
        ],
      };
      final c = await fixtures.setup(tester, backend);
      c.navigate(3);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Connection details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create routing rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose route'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('target:DIRECT')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validate and apply'));
      await tester.pumpAndSettle();
      expect(
        backend.appliedPatch!['rule'],
        r'PROCESS-PATH,C:\Apps\browser.exe,DIRECT',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('subscription preview requires applying the downloaded token', (
    tester,
  ) async {
    final backend = workspaceFixture();
    backend.profiles.first['url'] = 'https://example.com/subscription';
    final c = await fixtures.setup(tester, backend);
    c.navigate(2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Subscription update preview'), findsOneWidget);
    expect(backend.mutation, isNull);
    await tester.tap(find.text('Apply update'));
    await tester.pumpAndSettle();
    expect(backend.mutation!['token'], 'fixture-token');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'statistics and diagnosis fit compact windows with enlarged text',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = workspaceFixture();
      final c = await fixtures.setup(
        tester,
        backend,
        size: const Size(760, 580),
      );
      c.navigate(7);
      await tester.pumpAndSettle();
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      c.navigate(8);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Run diagnostics'));
      await tester.tap(find.text('Run diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('Technical details'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
