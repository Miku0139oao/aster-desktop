import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

import 'backend.dart';

class AppSettings {
  const AppSettings({
    this.language = 'zh_TW',
    this.theme = 'system',
    this.systemProxy = true,
    this.tun = false,
    this.allowLan = false,
    this.mixedPort = 7890,
    this.mode = 'rule',
    this.autoStart = false,
    this.subscriptionHours = 24,
  });
  final String language, theme, mode;
  final bool systemProxy, tun, allowLan, autoStart;
  final int mixedPort, subscriptionHours;
  factory AppSettings.fromJson(Json j) => AppSettings(
    language: j['language'] as String,
    theme: j['theme'] as String,
    mode: j['mode'] as String,
    systemProxy: j['systemProxy'] == true,
    tun: j['tun'] == true,
    allowLan: j['allowLan'] == true,
    autoStart: j['autoStart'] == true,
    mixedPort: j['mixedPort'] as int,
    subscriptionHours: j['subscriptionHours'] as int,
  );
  Json toJson() => {
    'language': language,
    'theme': theme,
    'mode': mode,
    'systemProxy': systemProxy,
    'tun': tun,
    'allowLan': allowLan,
    'autoStart': autoStart,
    'mixedPort': mixedPort,
    'subscriptionHours': subscriptionHours,
  };
  AppSettings copy(Json changes) =>
      AppSettings.fromJson({...toJson(), ...changes});
}

class Profile {
  Profile(this.json);
  final Json json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get content => json['content'] as String;
  String get url => json['url'] as String? ?? '';
  List<String> get warnings => (json['warnings'] as List? ?? []).cast<String>();
  DateTime? get updated => DateTime.tryParse(json['updated'] as String? ?? '');
}

class AppController extends ChangeNotifier {
  AppController(this.backend) {
    _subscription = backend.events.listen(_onEvent);
  }
  final DesktopBackend backend;
  AppSettings settings = const AppSettings();
  List<Profile> profiles = [];
  String activeId = '';
  Json service = {}, proxies = {}, connections = {};
  Map<String, String> selections = {};
  List<String> logs = [];
  List<Json> rules = [];
  bool running = false, busy = false, ready = false;
  String? error;
  String updateProgress = '';
  String coreVersion = '';
  void reportError(String? message) {
    error = message;
    notifyListeners();
  }

  double upload = 0, download = 0;
  int page = 0;
  Timer? _timer;
  StreamSubscription<Json>? _subscription;
  bool _polling = false;
  DateTime? _metricsAt;
  num _previousUp = 0, _previousDown = 0;
  final _refreshAttempts = <String, DateTime>{};
  Profile? get active => profiles.where((p) => p.id == activeId).firstOrNull;
  String get profileTarget {
    try {
      final doc = loadYaml(active?.content ?? '') as YamlMap;
      for (final rule in (doc['rules'] as List? ?? []).reversed) {
        final parts = (rule as String).split(',');
        if (parts.length > 1 && ['MATCH', 'FINAL'].contains(parts.first)) {
          return parts[1].trim();
        }
      }
      final groups = doc['proxy-groups'] as List? ?? [];
      return groups.where((g) => g['type'] == 'select').firstOrNull?['name']
              as String? ??
          'DIRECT';
    } catch (_) {
      return 'DIRECT';
    }
  }

  String get currentNode {
    if (settings.mode == 'direct') return 'DIRECT';
    var node = settings.mode == 'global'
        ? (running ? 'GLOBAL' : selections['GLOBAL'] ?? profileTarget)
        : profileTarget;
    final seen = <String>{};
    YamlMap? doc;
    try {
      doc = loadYaml(active?.content ?? '') as YamlMap?;
    } catch (_) {}
    while (seen.add(node)) {
      final live = running ? proxies[node] as Json? : null;
      final group = (doc?['proxy-groups'] as List? ?? [])
          .where((g) => g['name'] == node)
          .firstOrNull;
      final next =
          live?['now'] as String? ??
          selections[node] ??
          (group?['proxies'] as List?)?.firstOrNull as String?;
      if (next == null) break;
      node = next;
    }
    return node;
  }

  Future<void> _selectGlobalTarget() async {
    final result = await api('GET', '/proxies') as Json;
    final all = result['proxies'] as Json;
    final choices = (all['GLOBAL'] as Json?)?['all'] as List? ?? [];
    var target = selections['GLOBAL'] ?? profileTarget;
    if (!choices.contains(target)) target = profileTarget;
    if (!choices.contains(target)) return;
    await api('PUT', '/proxies/GLOBAL', {'name': target});
  }

  String tr(String zh, String en) => settings.language == 'en' ? en : zh;
  ThemeMode get themeMode => switch (settings.theme) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  Future<void> initialize() async {
    try {
      await refresh();
      ready = true;
    } catch (e) {
      error = e.toString();
      ready = true;
    }
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
  }

  Future<void> refresh() async {
    final result = await backend.call('state') as Json;
    final state = result['state'] as Json;
    settings = AppSettings.fromJson(state['settings'] as Json);
    profiles = (state['profiles'] as List? ?? [])
        .map((p) => Profile(p as Json))
        .toList();
    activeId = state['activeId'] as String? ?? '';
    selections = (state['selections'] as Json? ?? {}).map(
      (group, node) => MapEntry(group, node as String),
    );
    service = result['service'] as Json? ?? {};
    final core = result['core'] as Json;
    running = core['running'] == true;
    if (core['error'] != null) error = core['error'] as String;
    notifyListeners();
  }

  Future<bool> perform(Future<void> Function() task) async {
    if (busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await task();
      await refresh();
      if (running) await loadRuntime();
      return true;
    } catch (e) {
      error = e.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> toggle() => perform(() async {
    await backend.call(running ? 'disconnect' : 'connect');
    if (!running && settings.mode == 'global') await _selectGlobalTarget();
    if (running) {
      upload = 0;
      download = 0;
      _metricsAt = null;
    }
  });
  Future<bool> saveSettings(Json changes) => perform(() async {
    await backend.call('settings', settings.copy(changes).toJson());
    if (running && changes['mode'] == 'global') await _selectGlobalTarget();
  });
  Future<void> loadRuntime() async {
    final result = await api('GET', '/proxies') as Json;
    proxies = result['proxies'] as Json? ?? {};
    final version = await api('GET', '/version') as Json;
    coreVersion = version['version'] as String? ?? '';
    if (page == 3) connections = await api('GET', '/connections') as Json;
    if (page == 5) {
      final r = await api('GET', '/rules') as Json;
      rules = (r['rules'] as List? ?? []).cast<Json>();
    }
    notifyListeners();
  }

  Future<dynamic> api(String method, String path, [dynamic body]) => backend
      .call('controller', {'method': method, 'path': path, 'body': body});
  Future<bool> selectNode(String group, String node) => perform(() async {
    if (running) {
      await api('PUT', '/proxies/${Uri.encodeComponent(group)}', {
        'name': node,
      });
      if (settings.mode == 'global' && group != 'GLOBAL') {
        await api('PUT', '/proxies/GLOBAL', {'name': group});
      }
    } else {
      await backend.call('rememberSelection', {'group': group, 'name': node});
      if (settings.mode == 'global') {
        await backend.call('rememberSelection', {
          'group': 'GLOBAL',
          'name': group,
        });
      }
    }
  });
  Future<int?> testNode(String name) async {
    try {
      final result = await api(
        'GET',
        '/proxies/${Uri.encodeComponent(name)}/delay?timeout=5000&url=${Uri.encodeComponent('https://www.gstatic.com/generate_204')}',
      ) as Json;
      final proxy = proxies[name] as Json?;
      if (proxy != null) {
        proxy['history'] = [
          {'delay': result['delay']},
        ];
        notifyListeners();
      }
      return result['delay'] as int?;
    } catch (e) {
      error = tr(
        '節點無法連線，請換一個節點。',
        'This node is unreachable. Try another node.',
      );
      notifyListeners();
      return null;
    }
  }

  Future<void> poll() async {
    if (_polling || busy || !ready) return;
    _polling = true;
    try {
      final wasRunning = running;
      await refresh();
      if (wasRunning && !running) {
        error = tr(
          '代理已停止，請重新連線。',
          'The proxy stopped. Reconnect to try again.',
        );
        upload = 0;
        download = 0;
      }
      if (running) {
        if (page == 1) await loadRuntime();
        if (page == 3 || settings.tun) {
          connections = await api('GET', '/connections') as Json;
          if (settings.tun) {
            final now = DateTime.now();
            final up = connections['uploadTotal'] as num? ?? 0;
            final down = connections['downloadTotal'] as num? ?? 0;
            final seconds = _metricsAt == null
                ? 0.0
                : now.difference(_metricsAt!).inMilliseconds / 1000;
            if (seconds > 0) {
              upload = ((up - _previousUp) / seconds).clamp(0, double.infinity);
              download = ((down - _previousDown) / seconds).clamp(
                0,
                double.infinity,
              );
            }
            _metricsAt = now;
            _previousUp = up;
            _previousDown = down;
          }
        }
        if (page == 4) {
          logs = (await backend.call('logs') as List? ?? []).cast<String>();
        }
      }
      // Native macOS TUN changes must pass through XPC, including scheduled refreshes.
      if (Platform.isMacOS && settings.subscriptionHours > 0) {
        final now = DateTime.now();
        for (final profile in profiles.where((p) => p.url.isNotEmpty)) {
          if (profile.updated != null &&
              now.difference(profile.updated!).inHours >=
                  settings.subscriptionHours &&
              now
                      .difference(
                        _refreshAttempts[profile.id] ?? DateTime(2000),
                      )
                      .inMinutes >=
                  5) {
            _refreshAttempts[profile.id] = now;
            await backend.call('refresh', {'id': profile.id});
            await refresh();
          }
        }
      }
      notifyListeners();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  void _onEvent(Json event) {
    switch (event['event']) {
      case 'traffic':
        final value = event['data'] as Json;
        upload = (value['up'] as num? ?? 0).toDouble();
        download = (value['down'] as num? ?? 0).toDouble();
      case 'connections':
        connections = event['data'] as Json;
      case 'profilesChanged':
        unawaited(refresh());
      case 'updateProgress':
        updateProgress = event['data'] as String;
      case 'engineStopped':
        running = false;
        error = tr(
          '背景程序已停止，請重新開啟 Aster Desktop。',
          'The desktop engine stopped. Reopen Aster Desktop.',
        );
      default:
        return;
    }
    notifyListeners();
  }

  void navigate(int index) {
    page = index;
    notifyListeners();
    if (running) {
      unawaited(
        loadRuntime().catchError((Object e) {
          error = e.toString();
          notifyListeners();
        }),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

String bytes(num value) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}
