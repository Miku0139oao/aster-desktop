import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aster_desktop/backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercise the actual RPC/XPC orchestration with framed process replies and a
// mocked native channel. No OS proxy, helper or TUN adapter is installed.
class _Input extends Fake implements IOSink {
  _Input(this.onLine, this.onClose);
  final void Function(String) onLine;
  final Future<void> Function() onClose;
  @override
  void writeln([Object? object = '']) => onLine(object.toString());
  @override
  Future<void> close() => onClose();
}

class _Process extends Fake implements Process {
  _Process(this.handle) {
    input = _Input(
      (line) {
        final request = jsonDecode(line) as Json;
        Json response;
        try {
          response = {'id': request['id'], 'result': handle(request)};
        } catch (e) {
          response = {
            'id': request['id'],
            'error': {'message': e.toString()},
          };
        }
        output.add(utf8.encode('${jsonEncode(response)}\n'));
      },
      () async {
        await output.close();
        await errors.close();
        exited.complete(0);
      },
    );
  }
  final dynamic Function(Json) handle;
  late final _Input input;
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  @override
  IOSink get stdin => input;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
}

class _MacSession {
  _MacSession({this.tun = true, this.failure = ''}) {
    backend = ProcessBackend.forTesting(_Process(rpc), nativeMac: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native);
  }
  static const channel = MethodChannel('app.astercore/privilege');
  final bool tun;
  final String failure;
  late final ProcessBackend backend;
  bool rootRunning = false, userRunning = false, proxyOwned = false;
  int rootPid = 100;
  String node = 'First';
  final order = <String>[];
  final sessions = <String>[];
  bool loseRecoveryStatus = false;
  bool rejectProxyStopOnce = false;

  dynamic rpc(Json request) {
    final method = request['method'] as String;
    final params = request['params'] as Json;
    order.add('desktop:$method');
    switch (method) {
      case 'state':
        return {
          'state': {
            'settings': {'tun': tun, 'systemProxy': !tun, 'mixedPort': 7890},
            'activeId': 'fixture',
            'profiles': [
              {'id': 'fixture', 'content': 'proxies: []'},
            ],
            'selections': {'Auto': 'Backup'},
          },
          'core': {'running': userRunning},
        };
      case 'connect':
        userRunning = true;
      case 'disconnect':
        userRunning = false;
      case 'updateCore':
        if (tun && (!rootRunning || params['externalProxy'] != true)) {
          throw StateError('TUN was disconnected before the user download');
        }
        if (failure == 'user-restart') {
          userRunning = false;
          throw const BackendException('previous core could not restart');
        }
        return {'active': 'verified-user-copy'};
      case 'recordExternalTraffic':
        sessions.add(params['session'] as String);
    }
    return true;
  }

  Future<dynamic> native(MethodCall call) async {
    if (call.method == 'serviceStatus') {
      return {'installed': true, 'approved': true};
    }
    final req = jsonDecode(call.arguments as String) as Json;
    final method = req['method'] as String;
    final params = req['params'] as Json;
    order.add('service:$method');
    dynamic result = true;
    String? error;
    switch (method) {
      case 'start':
        rootRunning = true;
      case 'stop':
        rootRunning = false;
      case 'status':
        if (loseRecoveryStatus && order.contains('service:updateCore')) {
          error = 'recovery query unavailable';
        } else {
          result = {'running': rootRunning, 'pid': rootPid};
        }
      case 'proxyStart':
        proxyOwned = true;
      case 'proxyStop':
        if (rejectProxyStopOnce) {
          rejectProxyStopOnce = false;
          error = 'proxy cleanup unavailable';
        } else {
          proxyOwned = false;
        }
      case 'updateCore':
        if (tun && !rootRunning) error = 'TUN disconnected before download';
        if (failure == 'checksum') {
          error = 'checksum does not match';
        } else if (failure == 'rollback') {
          rootPid++;
          node = 'First';
          error = 'new startup failed; previous core restored';
        } else {
          rootPid++;
          node = 'First';
        }
      case 'controller':
        if (params['method'] == 'PUT') {
          node = (params['body'] as Json)['name'] as String;
        } else {
          result = {'uploadTotal': 10, 'downloadTotal': 20, 'connections': []};
        }
    }
    return jsonEncode({
      'id': req['id'],
      if (error != null) 'error': {'message': error} else 'result': result,
    });
  }

  Future<void> close() async {
    loseRecoveryStatus = false;
    await backend.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['', 'checksum', 'rollback']) {
    test(
      'Mac TUN update retains its proxy, pin and statistics: $failure',
      () async {
        final f = _MacSession(failure: failure);
        addTearDown(f.close);
        await f.backend.call('connect');
        await f.backend.call('state');
        final previousSession = f.sessions.last;
        if (failure.isEmpty) {
          await f.backend.call('updateCore');
        } else {
          await expectLater(
            f.backend.call('updateCore'),
            throwsA(isA<BackendException>()),
          );
        }
        expect(f.rootRunning, isTrue);
        expect(f.node, 'Backup');
        expect(
          f.order,
          containsAllInOrder(['desktop:updateCore', 'service:updateCore']),
        );
        expect(f.order, isNot(contains('service:stop')));
        await f.backend.call('state');
        expect(f.sessions.last == previousSession, failure == 'checksum');
        await f.backend.call('disconnect');
        expect(f.rootRunning, isFalse);
      },
    );
  }
  test(
    'Mac preserves update error and TUN ownership on recovery IPC failure',
    () async {
      final f = _MacSession(failure: 'checksum')..loseRecoveryStatus = true;
      addTearDown(f.close);
      await f.backend.call('connect');
      await expectLater(
        f.backend.call('updateCore'),
        throwsA(
          predicate((e) => e.toString().contains('checksum does not match')),
        ),
      );
      await f.backend.call('disconnect');
      expect(f.rootRunning, isFalse);
    },
  );
  test('Mac failed normal restart restores its owned system proxy', () async {
    final f = _MacSession(tun: false, failure: 'user-restart');
    addTearDown(f.close);
    await f.backend.call('connect');
    expect(f.proxyOwned, isTrue);
    await expectLater(
      f.backend.call('updateCore'),
      throwsA(isA<BackendException>()),
    );
    expect(f.proxyOwned, isFalse);
    expect(f.userRunning, isFalse);
    expect(f.order, contains('service:proxyStop'));
  });
  test(
    'Mac keeps cleanup ownership when restoring its proxy initially fails',
    () async {
      final f = _MacSession(tun: false, failure: 'user-restart')
        ..rejectProxyStopOnce = true;
      addTearDown(f.close);
      await f.backend.call('connect');
      await expectLater(
        f.backend.call('updateCore'),
        throwsA(isA<BackendException>()),
      );
      expect(f.proxyOwned, isTrue);
      await f.backend.call('state');
      expect(f.proxyOwned, isFalse);
    },
  );
}
