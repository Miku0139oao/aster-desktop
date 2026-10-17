import 'dart:convert';

import 'inspection.dart';

class LogEntry {
  LogEntry(String line) {
    raw = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
    Map? json;
    try {
      final value = jsonDecode(raw);
      if (value is Map) json = value;
    } catch (_) {
      /* Plain text logs are supported. */
    }
    final levelMatch = RegExp(
      r'\blevel\s*=\s*"?([a-zA-Z]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    final bracket = RegExp(
      r'\[(trace|debug|info|warn(?:ing)?|error|fatal|panic)\]',
      caseSensitive: false,
    ).firstMatch(raw);
    final parsedLevel =
        (json?['level'] ?? json?['type'] ?? levelMatch?[1] ?? bracket?[1] ?? '')
            .toString()
            .toLowerCase();
    level = switch (parsedLevel) {
      'warn' => 'warning',
      'panic' || 'fatal' => 'error',
      'trace' => 'debug',
      '' => 'info',
      _ => parsedLevel,
    };
    final timeMatch = RegExp(r'\btime=(?:"([^"]+)"|(\S+))').firstMatch(raw);
    timestamp =
        (json?['time'] ??
                json?['timestamp'] ??
                timeMatch?[1] ??
                timeMatch?[2] ??
                '')
            .toString();
    var parsedMessage =
        (json?['msg'] ?? json?['message'] ?? json?['payload'] ?? '').toString();
    if (parsedMessage.isEmpty) {
      final messageMatch = RegExp(r'\bmsg=(.*)$').firstMatch(raw);
      parsedMessage = messageMatch?[1] ?? raw;
      if (parsedMessage.startsWith('"') && parsedMessage.endsWith('"')) {
        try {
          parsedMessage = jsonDecode(parsedMessage) as String;
        } catch (_) {
          parsedMessage = parsedMessage.substring(1, parsedMessage.length - 1);
        }
      }
    }
    message = parsedMessage;
    source = raw.startsWith('Desktop:') || raw.startsWith('Core rollback:')
        ? 'desktop'
        : 'core';
  }
  late final String raw, level, timestamp, message, source;
  bool matches(String query) => matchesInspectionQuery(query, raw, {
    'level': level,
    'source': source,
    'message': message,
  });
}
