import 'dart:convert';

import 'package:aster_desktop/android_apps.dart';
import 'package:aster_desktop/backend.dart';
import 'package:aster_desktop/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.astercore/android');
  late Map<String, dynamic> routing;
  late List<Map<String, dynamic>> saved;

  setUp(() {
    routing = {
      'mode': 'all',
      'apps': {'com.beta': 'direct'},
    };
    saved = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'appRouting':
              return jsonEncode(routing);
            case 'listApplications':
              return jsonEncode([
                {
                  'package': 'com.alpha',
                  'name': 'Alpha',
                  'system': false,
                  'enabled': true,
                  'icon': '',
                },
                {
                  'package': 'com.beta',
                  'name': 'Beta',
                  'system': true,
                  'enabled': true,
                  'icon': '',
                },
              ]);
            case 'saveAppRouting':
              final value = jsonDecode(
                (call.arguments as Map)['routing'] as String,
              ) as Map<String, dynamic>;
              routing = value;
              saved.add(value);
              return jsonEncode(value);
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<AppController> pumpPage(WidgetTester tester) async {
    final controller = AppController(AndroidBackend());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AndroidApplicationsPage(c: controller)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('loads packages and searches by name', (tester) async {
    await pumpPage(tester);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.textContaining('com.beta'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('android-app-search')),
      'alpha',
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('changes one application route and persists it', (tester) async {
    await pumpPage(tester);
    final alpha = find.byKey(const ValueKey('android-app:com.alpha'));
    await tester.tap(find.descendant(of: alpha, matching: find.text('代理')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直連').last);
    await tester.pumpAndSettle();

    expect(saved, isNotEmpty);
    expect(saved.last['apps'], containsPair('com.alpha', 'direct'));
  });

  testWidgets('multi-select applies a batch route', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('多選應用程式'));
    await tester.pumpAndSettle();

    final beta = find.byKey(const ValueKey('android-app:com.beta'));
    await tester.tap(
      find.descendant(of: beta, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(find.text('已選 1 個'), findsOneWidget);

    await tester.tap(find.text('排除').last);
    await tester.pumpAndSettle();
    expect(saved, isNotEmpty);
    expect(saved.last['apps'], containsPair('com.beta', 'exclude'));
  });

  testWidgets('warns when selected-only mode has no proxied app', (
    tester,
  ) async {
    routing = {'mode': 'selected', 'apps': <String, dynamic>{}};
    await pumpPage(tester);
    expect(find.textContaining('連線會失敗'), findsOneWidget);
  });
}
