import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef Json = Map<String, dynamic>;

abstract class DesktopBackend {
  Stream<Json> get events;
  Future<dynamic> call(String method, [Json? params]);
  Future<void> close();
}

class ProcessBackend implements DesktopBackend {
  ProcessBackend._(this.process);
  final Process process;
  final _events = StreamController<Json>.broadcast();
  final _pending = <int, Completer<dynamic>>{};
  static const _native = MethodChannel('app.astercore/privilege');
  int _next = 0;
  bool _macRunning = false;
  bool _macProxy = false;
  bool _closed = false;
  String _macTrafficSession = '';
  @override
  Stream<Json> get events => _events.stream;

  static Future<ProcessBackend> start({Directory? dataDirectory}) async {
    final data = dataDirectory ?? await getApplicationSupportDirectory();
    await data.create(recursive: true);
    final executable = File(Platform.resolvedExecutable);
    var directory = executable.parent.path;
    if (Platform.isMacOS) {
      directory = '${executable.parent.parent.path}/Resources';
    }
    final development = Directory.current.path;
    final suffix = Platform.isWindows ? '.exe' : '';
    var bridge = '$directory/aster-bridge$suffix';
    if (!await File(bridge).exists()) {
      bridge = '$development/.build/aster-bridge$suffix';
    }
    if (!await File(bridge).exists()) {
      throw const BackendException(
        'The desktop engine is missing. Reinstall Aster Desktop.',
      );
    }
    final core = '${File(bridge).parent.path}/aster-core$suffix';
    final process = await Process.start(bridge, [
      '--data',
      data.path,
      '--core',
      core,
      '--gui',
      executable.path,
    ]);
    final backend = ProcessBackend._(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final value = jsonDecode(line) as Json;
            if (value.containsKey('event')) {
              backend._events.add(value);
            } else {
              final completer = backend._pending.remove(value['id']);
              if (completer == null) return;
              if (value['error'] != null) {
                completer.completeError(
                  BackendException(value['error']['message'] as String),
                );
              } else {
                completer.complete(value['result']);
              }
            }
          } catch (_) {
            // Diagnostic output is not an RPC response.
          }
        }, onDone: () => backend._failPending());
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          backend._events.add({'event': 'diagnostic', 'data': line});
        });
    return backend;
  }

  void _failPending() {
    for (final completer in _pending.values) {
      completer.completeError(
        const BackendException(
          'The desktop engine stopped. Reopen Aster Desktop.',
        ),
      );
    }
    _pending.clear();
    if (!_closed) _events.add({'event': 'engineStopped', 'data': null});
  }

  Future<dynamic> _rpc(String method, [Json? params]) {
    final id = ++_next;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params ?? {}}),
    );
    return completer.future.timeout(
      Duration(minutes: method == 'updateCore' ? 20 : 3),
      onTimeout: () {
        _pending.remove(id);
        throw const BackendException(
          'The operation timed out. Check your connection and try again.',
        );
      },
    );
  }

  Future<dynamic> _xpc(String method, [Json? params]) async {
    final message = jsonEncode({
      'id': ++_next,
      'method': method,
      'params': params ?? {},
    });
    final reply = await _native
        .invokeMethod<String>('serviceCall', message)
        .timeout(Duration(minutes: method == 'updateCore' ? 10 : 4));
    final response = jsonDecode(reply!) as Json;
    if (response['error'] != null) {
      throw BackendException(response['error']['message'] as String);
    }
    return response['result'];
  }

  @override
  Future<dynamic> call(String method, [Json? params]) async {
    if (!Platform.isMacOS) return _rpc(method, params);
    if (method == 'listApplications') {
      final applications = await _rpc(method, params) as List;
      try {
        final paths = applications
            .where((app) => app['installed'] == true)
            .take(256)
            .map((app) => app['path'] as String)
            .toList();
        final icons = await _native.invokeMapMethod<String, String>(
          'applicationIcons',
          paths,
        );
        for (final app in applications) {
          if (icons?[app['path']] != null) app['icon'] = icons![app['path']];
        }
      } on PlatformException {
        /* Names and selection work without icons. */
      }
      return applications;
    }
    if (method == 'state') {
      final result = await _rpc(method, params) as Json;
      result['service'] =
          await _native.invokeMapMethod<String, dynamic>('serviceStatus') ??
          {'installed': false};
      if (_macRunning) {
        try {
          result['core'] = await _xpc('status');
          _macRunning = (result['core'] as Json)['running'] == true;
        } catch (_) {
          // Keep ownership on an IPC failure so Disconnect still reaches XPC.
          rethrow;
        }
        if (_macRunning) {
          try {
            final metrics = await _xpc('controller', {
              'method': 'GET',
              'path': '/connections',
            });
            await _rpc('recordExternalTraffic', {
              'session': _macTrafficSession,
              'up': metrics['uploadTotal'] ?? 0,
              'down': metrics['downloadTotal'] ?? 0,
              'connections': metrics['connections'] ?? [],
            });
          } catch (_) {
            // Statistics are optional; a failed sample must not orphan TUN.
          }
        }
      }
      if (_macProxy && (result['core'] as Json)['running'] != true) {
        await _xpc('proxyStop');
        _macProxy = false;
      }
      return result;
    }
    if (method == 'diagnose' && _macRunning) {
      return _rpc(method, {
        'externalStatus': await _xpc('status'),
        'externalService':
            await _native.invokeMapMethod<String, dynamic>('serviceStatus') ??
            {},
      });
    }
    if (method == 'installService' || method == 'uninstallService') {
      if (method == 'uninstallService') {
        final snapshot = await call('state') as Json;
        if ((snapshot['core'] as Json)['running'] == true) {
          throw const BackendException(
            'Disconnect before removing the background service.',
          );
        }
      }
      return _native.invokeMethod(
        method == 'installService' ? 'installService' : 'uninstallService',
      );
    }
    if (method == 'disconnect' && _macProxy) {
      await _xpc('proxyStop');
      _macProxy = false;
      return _rpc('disconnect');
    }
    if (method == 'checkUpdates' && _macRunning) {
      return _rpc(method, {'externalProxy': true});
    }
    if (method == 'updateCore') {
      final status = await _native.invokeMapMethod<String, dynamic>(
        'serviceStatus',
      );
      final snapshot = await _rpc('state') as Json;
      final settings = (snapshot['state'] as Json)['settings'] as Json;
      try {
        // Download the user copy while the currently owned TUN stays online.
        final result = await _rpc(method, {
          ...?params,
          'externalProxy': _macRunning,
        });
        if (_macRunning || status?['approved'] == true) {
          _events.add({'event': 'updateProgress', 'data': 'service'});
          try {
            await _xpc('updateCore', {
              'port':
                  _macRunning || (snapshot['core'] as Json)['running'] == true
                  ? settings['mixedPort']
                  : 0,
            });
          } catch (e) {
            throw BackendException(
              'Desktop core updated, but background core could not update: $e',
            );
          }
          if (_macRunning) {
            _macTrafficSession = 'mac:${DateTime.now().microsecondsSinceEpoch}';
            // Include explicit choices inside automatic groups. The helper
            // snapshots selectors; an automatic group's current winner alone
            // does not tell it whether the user pinned that node.
            for (final entry
                in ((snapshot['state'] as Json)['selections'] as Json)
                    .entries) {
              try {
                await _xpc('controller', {
                  'method': 'PUT',
                  'path': '/proxies/${Uri.encodeComponent(entry.key)}',
                  'body': {'name': entry.value},
                });
              } on BackendException {
                // A removed node must not prevent reconnection.
              }
            }
          }
        }
        _events.add({'event': 'updateProgress', 'data': 'complete'});
        return result;
      } finally {
        if (_macProxy) {
          final snapshot = await _rpc('state') as Json;
          if ((snapshot['core'] as Json)['running'] == true) {
            await _xpc('proxyStart', {
              'port':
                  ((snapshot['state'] as Json)['settings']
                      as Json)['mixedPort'],
            });
          } else {
            _macProxy = false;
          }
        }
      }
    }
    if (method == 'connect') {
      final snapshot = await _rpc('state') as Json;
      final state = snapshot['state'] as Json;
      final settings = state['settings'] as Json;
      if (settings['tun'] == true) {
        final profiles = state['profiles'] as List;
        final profile = profiles
            .cast<Json>()
            .where((p) => p['id'] == state['activeId'])
            .firstOrNull;
        if (profile == null) {
          throw const BackendException(
            'Import a configuration before connecting.',
          );
        }
        await _xpc('start', {
          'content': profile['content'],
          'settings': settings,
        });
        _macRunning = true;
        _macTrafficSession = 'mac:${DateTime.now().microsecondsSinceEpoch}';
        for (final entry in (state['selections'] as Json).entries) {
          try {
            await _xpc('controller', {
              'method': 'PUT',
              'path': '/proxies/${Uri.encodeComponent(entry.key)}',
              'body': {'name': entry.value},
            });
          } on BackendException {
            // A refreshed subscription can remove a previously selected node.
          }
        }
        return _xpc('status');
      }
      if (settings['systemProxy'] == true) {
        final status = await _native.invokeMapMethod<String, dynamic>(
          'serviceStatus',
        );
        if (status?['approved'] != true) {
          await _native.invokeMethod('installService');
          throw const BackendException(
            'Approve Aster Desktop in System Settings → Login Items & Extensions, then connect again. macOS requires authorization to change network proxy settings.',
          );
        }
        final result = await _rpc('connect', {'skipSystemProxy': true});
        try {
          await _xpc('proxyStart', {'port': settings['mixedPort']});
          _macProxy = true;
        } catch (_) {
          await _rpc('disconnect');
          rethrow;
        }
        return result;
      }
    }
    if (_macRunning) {
      if (method == 'disconnect') {
        try {
          final metrics = await _xpc('controller', {
            'method': 'GET',
            'path': '/connections',
          });
          await _rpc('recordExternalTraffic', {
            'session': _macTrafficSession,
            'up': metrics['uploadTotal'] ?? 0,
            'down': metrics['downloadTotal'] ?? 0,
            'connections': metrics['connections'] ?? [],
          });
        } catch (_) {
          /* Stop remains available if metrics are unavailable. */
        }
        await _xpc('stop');
        _macRunning = false;
        return true;
      }
      if (method == 'controller' || method == 'logs') {
        final result = await _xpc(method, params);
        if (method == 'controller' &&
            params?['method'] == 'PUT' &&
            (params?['path'] as String).startsWith('/proxies/')) {
          await _rpc('rememberSelection', {
            'group': Uri.decodeComponent(
              (params!['path'] as String).substring('/proxies/'.length),
            ),
            'name': (params['body'] as Json)['name'],
          });
        }
        return result;
      }
      if (method == 'settings' ||
          method == 'edit' ||
          method == 'restore' ||
          method == 'patchProfile' ||
          method == 'manageObject' ||
          method == 'manageRules' ||
          method == 'batchApplicationRules' ||
          method == 'applyRefresh' ||
          method == 'activate' ||
          method == 'refresh') {
        final snapshot = await _rpc('state') as Json;
        final state = snapshot['state'] as Json;
        final previous = (state['profiles'] as List).cast<Json>().firstWhere(
          (p) => p['id'] == state['activeId'],
        );
        if (method == 'settings' &&
            (params!['tun'] != true ||
                params['mixedPort'] !=
                    (state['settings'] as Json)['mixedPort'] ||
                (params['tunInterface'] ?? '') !=
                    ((state['settings'] as Json)['tunInterface'] ?? ''))) {
          throw const BackendException(
            'Disconnect before changing how applications connect.',
          );
        }
        final result = await _rpc(method, params);
        final next = await _rpc('state') as Json;
        final nextState = next['state'] as Json;
        final profile = (nextState['profiles'] as List).cast<Json>().firstWhere(
          (p) => p['id'] == nextState['activeId'],
        );
        final previousSettings = state['settings'] as Json;
        final nextSettings = nextState['settings'] as Json;
        if (profile['content'] == previous['content'] &&
            previousSettings['mode'] == nextSettings['mode'] &&
            previousSettings['allowLan'] == nextSettings['allowLan']) {
          return result;
        }
        try {
          await _xpc('apply', {
            'content': profile['content'],
            'settings': nextState['settings'],
          });
        } catch (_) {
          if (profile['id'] == previous['id'] &&
              profile['content'] != previous['content']) {
            await _rpc('restore', {'id': previous['id']});
          }
          await _rpc('activate', {'id': previous['id']});
          await _rpc('settings', state['settings'] as Json);
          rethrow;
        }
        return result;
      }
    }
    return _rpc(method, params);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await call('disconnect');
    } finally {
      _closed = true;
      await process.stdin.close();
      await process.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await _events.close();
    }
  }
}

class BackendException implements Exception {
  const BackendException(this.message);
  final String message;
  @override
  String toString() => message;
}
