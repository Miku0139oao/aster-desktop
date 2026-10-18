// Runs real competing processes, rather than same-process advisory locks.
// No Flutter engine, bridge, core, service or system network changes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aster_desktop/single_instance.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    SingleInstance? instance;
    try {
      instance = await SingleInstance.acquire(
        Directory(args[1]),
        timeout: args.first == 'timeout'
            ? const Duration(milliseconds: 500)
            : const Duration(seconds: 4),
        onActivate: () async {
          stdout.writeln('activated');
        },
      );
    } on InstanceActivationException {
      if (args.first != 'timeout') rethrow;
      stdout.writeln('blocked');
      return;
    }
    if (instance == null) {
      stdout.writeln('secondary');
      return;
    }
    stdout.writeln('primary');
    if (args.first == 'probe') {
      await instance.close();
      return;
    }
    await stdin.first;
    await instance.close();
    return;
  }
  final directory = await Directory.systemTemp.createTemp(
    'aster-instance-test-',
  );
  final processes = <Process>[];
  Future<Process> spawn(String mode) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      mode,
      directory.path,
    ]);
    processes.add(process);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    return process;
  }

  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<String> output(Process p) => p.stdout
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 15));
  try {
    final owner = await spawn('hold');
    final lines = StreamIterator(
      owner.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    await lines.moveNext().timeout(const Duration(seconds: 10));
    check(lines.current == 'primary', 'first process must own the lease');
    final competitors = await Future.wait(
      List.generate(8, (_) => spawn('probe')),
    );
    final replies = await Future.wait(competitors.map(output));
    check(
      replies.every((r) => r.trim() == 'secondary'),
      'duplicate process became an owner: $replies',
    );
    for (var i = 0; i < 8; i++) {
      check(await lines.moveNext(), 'activation missing');
      check(lines.current == 'activated', 'activation not delivered');
    }
    final codes = await Future.wait(competitors.map((p) => p.exitCode));
    check(codes.every((code) => code == 0), 'duplicate launch failed');

    final endpoint = jsonDecode(
      await File('${directory.path}/desktop.instance.json').readAsString(),
    ) as Map;
    final invalid = await Socket.connect(
      InternetAddress.loopbackIPv4,
      endpoint['port'] as int,
    );
    invalid.write('activate invalid-token\n');
    await invalid.flush();
    check(
      await invalid.cast<List<int>>().transform(utf8.decoder).join() == '',
      'unauthenticated activation acknowledged',
    );
    invalid.destroy();
    final valid = await spawn('probe');
    check(
      (await output(valid)).trim() == 'secondary',
      'owner lost after invalid request',
    );
    await lines.moveNext();
    check(
      lines.current == 'activated',
      'valid activation missing after invalid request',
    );
    final metadata = File('${directory.path}/desktop.instance.json');
    final original = await metadata.readAsString();
    await metadata.writeAsString(jsonEncode({...endpoint, 'token': 'x' * 44}));
    final blocked = await spawn('timeout');
    check(
      (await output(blocked)).trim() == 'blocked',
      'unresponsive owner must not permit a duplicate',
    );
    check(await blocked.exitCode == 0, 'timeout should fail closed');
    await metadata.writeAsString(original);

    owner.stdin.writeln('quit');
    check(await owner.exitCode == 0, 'clean exit failed');
    await lines.cancel();
    final restart = await spawn('hold');
    final restartLines = StreamIterator(
      restart.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    await restartLines.moveNext();
    check(
      restartLines.current == 'primary',
      'lease not released on clean quit',
    );
    restart.kill(ProcessSignal.sigkill);
    await restart.exitCode;
    await restartLines.cancel();
    final recovery = await spawn('probe');
    check(
      (await output(recovery)).trim() == 'primary',
      'stale lock/endpoint blocked crash recovery',
    );
    check(await recovery.exitCode == 0, 'recovery process failed');
    final simultaneous = await Future.wait(
      List.generate(8, (_) => spawn('hold')),
    );
    final readers = simultaneous
        .map(
          (p) => StreamIterator(
            p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
          ),
        )
        .toList();
    final first = await Future.wait(
      readers.map((r) async {
        check(await r.moveNext(), 'concurrent startup returned no result');
        return r.current;
      }),
    ).timeout(const Duration(seconds: 15));
    check(
      first.where((r) => r == 'primary').length == 1 &&
          first.where((r) => r == 'secondary').length == 7,
      'simultaneous first launches created duplicate owners: $first',
    );
    for (var i = 0; i < simultaneous.length; i++) {
      if (first[i] == 'primary') simultaneous[i].stdin.writeln('quit');
      await readers[i].cancel();
    }
    check(
      (await Future.wait(simultaneous.map((p) => p.exitCode)))
          .every((code) => code == 0),
      'simultaneous launch failed',
    );
    stdout.writeln(
      'PASS: concurrent first launch and 8 duplicates, authenticated activation, fail-closed timeout, clean quit, crash recovery',
    );
  } finally {
    for (final process in processes) {
      process.kill(ProcessSignal.sigkill);
    }
    await Future.wait(processes.map((process) => process.exitCode));
    await directory.delete(recursive: true);
  }
}
