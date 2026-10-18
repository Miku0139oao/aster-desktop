import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

/// A per-user lease, shared by installed and portable copies. The OS releases
/// the lock on a crash; the lock file must never be unlinked (Unix inode locks).
/// Only a fixed, authenticated activation request is accepted over loopback.
class SingleInstance {
  SingleInstance._(this._lock, this._server, this._token, this._activate) {
    _server.listen(_receive);
  }

  final RandomAccessFile _lock;
  final ServerSocket _server;
  final String _token;
  final Future<void> Function() _activate;
  bool _closed = false;

  /// Returns null after successfully activating the existing instance. Never
  /// starts another owner when an existing owner is slow or unresponsive.
  static Future<SingleInstance?> acquire(
    Directory directory, {
    required Future<void> Function() onActivate,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await directory.create(recursive: true);
    final lockFile = File('${directory.path}/desktop.instance.lock');
    final endpoint = File('${directory.path}/desktop.instance.json');
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final lock = await lockFile.open(mode: FileMode.append);
      var acquired = false;
      try {
        await lock.lock(FileLock.exclusive, 0, 1);
        acquired = true;
      } on FileSystemException {
        await lock.close();
      }
      if (acquired) {
        ServerSocket? server;
        try {
          server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          final random = Random.secure();
          final token = base64Url.encode(
            List<int>.generate(32, (_) => random.nextInt(256)),
          );
          // Use a separate file: Windows locks also prevent reads of the
          // locked byte. Publish atomically, with private Unix permissions.
          final pending = File('${endpoint.path}.$pid.tmp');
          await pending.writeAsString(
            jsonEncode({'pid': pid, 'port': server.port, 'token': token}),
            flush: true,
          );
          if (!Platform.isWindows) {
            final mode = await Process.run('/bin/chmod', ['600', pending.path]);
            if (mode.exitCode != 0) {
              await pending.delete();
              throw const FileSystemException(
                'Could not protect activation credentials',
              );
            }
          }
          // Windows cannot replace a file while a competing launch is still
          // reading it. Keep the lease while retrying that short sharing race.
          for (var attempt = 0; ; attempt++) {
            try {
              await pending.rename(endpoint.path);
              break;
            } on FileSystemException {
              if (!Platform.isWindows || attempt >= 30) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          return SingleInstance._(lock, server, token, onActivate);
        } catch (_) {
          await server?.close();
          await lock.close();
          rethrow;
        }
      }
      try {
        final data = jsonDecode(await endpoint.readAsString()) as Map;
        final port = data['port'] as int;
        final token = data['token'] as String;
        final owner = data['pid'] as int;
        if (port < 1 || port > 65535 || token.length != 44 || owner < 1) {
          throw const FormatException('Invalid activation endpoint');
        }
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 600),
        );
        try {
          if (Platform.isWindows) {
            // A second launch has foreground rights. Pass them to the owner
            // before it asks window_manager to focus its existing window.
            DynamicLibrary.open('user32.dll')
                .lookupFunction<Int32 Function(Uint32), int Function(int)>(
                  'AllowSetForegroundWindow',
                )(owner);
          }
          socket.write('activate $token\n');
          await socket.flush();
          final reply = await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 2));
          if (reply == 'ok') return null;
        } finally {
          socket.destroy();
        }
      } on Object {
        // Includes an owner still publishing its endpoint, a stale endpoint
        // after a crash, and an owner exiting. Retry the OS lock each time.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const InstanceActivationException();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _receive(Socket socket) async {
    try {
      var received = 0;
      final request = await socket
          .cast<List<int>>()
          .timeout(const Duration(seconds: 2))
          .map((bytes) {
            received += bytes.length;
            if (received > 128) {
              throw const FormatException('Request too large');
            }
            return bytes;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      if (request == 'activate $_token' && !_closed) {
        await _activate().timeout(const Duration(seconds: 5));
        socket.write('ok\n');
        await socket.flush();
      }
    } on Object {
      // A malformed/local unauthenticated client cannot affect the owner.
    } finally {
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    await _lock.close();
    // Stale metadata is harmless and is replaced by the next lock owner.
  }
}

class InstanceActivationException implements Exception {
  const InstanceActivationException();
  @override
  String toString() =>
      'Aster Desktop 已在執行，但目前無法喚回視窗。請稍候，或從系統托盤開啟。\n'
      'Aster Desktop is already running but could not reveal its window. Wait a moment or open it from the tray.';
}
