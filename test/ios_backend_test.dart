import 'dart:convert';

import 'package:aster_desktop/backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.astercore/ios');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'generic calls use RPC and connect uses the tunnel entry point',
    () async {
      final invoked = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked.add(call.method);
        if (call.method == 'startVpn') {
          return jsonEncode({
            'id': 1,
            'result': {'running': true},
          });
        }
        if (call.method == 'call') {
          final args = call.arguments as Map<Object?, Object?>;
          final request =
              jsonDecode(args['request'] as String) as Map<String, dynamic>;
          return jsonEncode({
            'id': request['id'],
            'result': {'method': request['method']},
          });
        }
        if (call.method == 'initialRoute') return 'nodes';
        if (call.method == 'stopVpn') return '{"result":true}';
        return null;
      });

      final backend = IOSBackend();
      expect(await backend.call('state'), {'method': 'state'});
      expect(await backend.call('connect'), {'running': true});
      expect(await backend.initialRoute(), 'nodes');
      await backend.close();
      expect(invoked, ['call', 'startVpn', 'initialRoute', 'stopVpn']);
    },
  );
}
