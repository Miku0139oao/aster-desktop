import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';

/// Android split tunneling is enforced by VpnService.Builder, so this page
/// talks to the native package manager instead of the desktop process rules.
class AndroidApplicationsPage extends StatefulWidget {
  const AndroidApplicationsPage({super.key, required this.c});
  final AppController c;

  @override
  State<AndroidApplicationsPage> createState() =>
      _AndroidApplicationsPageState();
}

class _AndroidApplicationsPageState extends State<AndroidApplicationsPage> {
  final search = TextEditingController();
  final selected = <String>{};
  final icons = <String, Uint8List>{};
  Json routing = {'mode': 'all', 'apps': <String, dynamic>{}};
  List<Json> applications = [];
  String filter = 'all';
  bool loading = true;
  bool saving = false;
  bool multiple = false;
  String? error;

  AppController get c => widget.c;
  AndroidBackend get backend => c.backend as AndroidBackend;
  Map<String, dynamic> get modes =>
      Map<String, dynamic>.from(routing['apps'] as Map? ?? {});
  bool get selectedOnly => routing['mode'] == 'selected';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final values = await Future.wait<dynamic>([
        backend.appRouting(),
        backend.installedApplications(),
      ]);
      final value = values[0] as Json;
      final apps = (values[1] as List<Json>)
        ..sort(
          (a, b) => (a['name'] as String).toLowerCase().compareTo(
            (b['name'] as String).toLowerCase(),
          ),
        );
      if (!mounted) return;
      setState(() {
        routing = {
          'mode': value['mode'] == 'selected' ? 'selected' : 'all',
          'apps': Map<String, dynamic>.from(value['apps'] as Map? ?? {}),
        };
        applications = apps;
        icons.clear();
        for (final app in apps) {
          final encoded = app['icon'] as String?;
          if (encoded == null || encoded.isEmpty || encoded.length > 60000) {
            continue;
          }
          try {
            icons[app['package'] as String] = base64Decode(encoded);
          } on FormatException {
            // Initials remain available.
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String modeFor(Json app) {
    final value = modes[app['package']];
    if (value is String &&
        const {'proxy', 'direct', 'exclude'}.contains(value)) {
      return value;
    }
    // In selected-only mode an unlisted app is not added to VpnService, so it
    // does not use the VPN. In all mode it is proxied by default.
    return selectedOnly ? 'direct' : 'proxy';
  }

  String label(String mode) => switch (mode) {
    'direct' => c.tr('直連', 'Direct'),
    'exclude' => c.tr('排除', 'Exclude'),
    _ => c.tr('代理', 'Proxy'),
  };

  String detail(Json app) {
    final package = app['package'] as String;
    return app['system'] == true
        ? c.tr('$package・系統應用程式', '$package · system application')
        : package;
  }

  List<Json> get visible {
    final query = search.text.trim().toLowerCase();
    return applications.where((app) {
      if (filter != 'all' && modeFor(app) != filter) return false;
      if (query.isEmpty) return true;
      return '${app['name']} ${app['package']}'.toLowerCase().contains(query);
    }).toList();
  }

  int count(String mode) =>
      applications.where((app) => modeFor(app) == mode).length;

  Future<void> _save(
    Map<String, dynamic> changes, {
    String? mode,
  }) async {
    setState(() {
      saving = true;
      error = null;
      routing = {
        ...routing,
        'mode': ?mode,
        'apps': {...modes, ...changes},
      };
    });
    try {
      final saved = await backend.saveAppRouting(routing);
      if (!mounted) return;
      setState(() {
        routing = {
          'mode': saved['mode'] == 'selected' ? 'selected' : 'all',
          'apps': Map<String, dynamic>.from(saved['apps'] as Map? ?? {}),
        };
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      await _load();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _setMode(String package, String mode) => _save({package: mode});

  Future<void> _setSelectedOnly(bool value) =>
      _save(const {}, mode: value ? 'selected' : 'all');

  Future<void> _applyBatch(String mode) async {
    if (selected.isEmpty) return;
    final changes = {for (final package in selected) package: mode};
    setState(selected.clear);
    await _save(changes);
  }

  @override
  Widget build(BuildContext context) {
    if (c.backend is! AndroidBackend) {
      return Center(
        child: Text(
          c.tr(
            'Android 應用程式分流只在 Android 版提供。',
            'Android application routing is only available on Android.',
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.tr('Android 應用程式分流', 'Android application routing'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          c.tr(
                            '選擇哪些已安裝應用程式經由 Aster VPN。這些規則儲存在裝置上，更新訂閱或切換節點都不會清除。',
                            'Choose which installed applications use the Aster VPN. Rules are stored on this device and survive subscription updates and node changes.',
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            c.tr(
                              '只代理選取的應用程式',
                              'Proxy selected applications only',
                            ),
                          ),
                          subtitle: Text(
                            c.tr(
                              '關閉時，除非標記為直連或排除，所有應用程式都會經由 VPN。',
                              'When off, every application uses the VPN unless it is marked Direct or Exclude.',
                            ),
                          ),
                          value: selectedOnly,
                          onChanged: saving ? null : _setSelectedOnly,
                        ),
                        Text(
                          c.tr(
                            '變更會在下次連線時生效。直連與排除都會讓應用程式離開 VPN；排除不會留下核心規則。',
                            'Changes apply on the next connection. Direct and Exclude both keep an app outside the VPN; Exclude also skips the core hint.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (c.running) ...[
                          const SizedBox(height: 8),
                          Text(
                            c.tr(
                              '目前連線中，請重新連線以套用新的分流規則。',
                              'Connected now. Reconnect to apply the new routing.',
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (selectedOnly && count('proxy') == 0)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        c.tr(
                          '目前沒有任何應用程式標記為「代理」，連線會失敗。請先標記至少一個應用程式，或關閉「只代理選取的應用程式」。',
                          'No application is marked Proxy, so connecting will fail. Mark at least one application or turn off selected applications only.',
                        ),
                      ),
                    ),
                  ),
                if (error != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(error!),
                    ),
                  ),
                if (saving) const LinearProgressIndicator(),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('android-app-search'),
                        controller: search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: c.tr(
                            '搜尋應用程式或套件名稱',
                            'Search applications or packages',
                          ),
                          suffixIcon: search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: c.tr('清除搜尋', 'Clear search'),
                                  onPressed: () => setState(search.clear),
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: c.tr(
                        multiple ? '結束多選' : '多選應用程式',
                        multiple
                            ? 'Finish selecting'
                            : 'Select multiple applications',
                      ),
                      onPressed: () => setState(() {
                        multiple = !multiple;
                        if (!multiple) selected.clear();
                      }),
                      icon: Icon(multiple ? Icons.close : Icons.checklist),
                    ),
                    IconButton(
                      tooltip: c.tr('重新整理', 'Refresh'),
                      onPressed: loading ? null : _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final entry in {
                      'all': c.tr('全部', 'All'),
                      'proxy': c.tr('代理', 'Proxy'),
                      'direct': c.tr('直連', 'Direct'),
                      'exclude': c.tr('排除', 'Exclude'),
                    }.entries)
                      ChoiceChip(
                        key: ValueKey('android-app-filter-${entry.key}'),
                        label: Text(
                          entry.key == 'all'
                              ? entry.value
                              : '${entry.value} (${count(entry.key)})',
                        ),
                        selected: filter == entry.key,
                        onSelected: (_) => setState(() => filter = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        applications.isEmpty
                            ? c.tr(
                                '找不到已安裝的應用程式。',
                                'No installed applications were found.',
                              )
                            : c.tr(
                                '沒有符合條件的應用程式。',
                                'No applications match this filter.',
                              ),
                      ),
                    ),
                  )
                else
                  for (final app in visible) _row(app),
                const SizedBox(height: 72),
              ],
            ),
          ),
          if (multiple)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.tr(
                          '已選 ${selected.length} 個',
                          '${selected.length} selected',
                        ),
                      ),
                    ),
                    for (final mode in const ['proxy', 'direct', 'exclude'])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: FilledButton.tonal(
                          onPressed: selected.isEmpty || saving
                              ? null
                              : () => _applyBatch(mode),
                          child: Text(label(mode)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(Json app) {
    final package = app['package'] as String;
    final mode = modeFor(app);
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('android-app:$package'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: SizedBox(
        width: multiple ? 88 : 44,
        child: Row(
          children: [
            if (multiple)
              Checkbox(
                value: selected.contains(package),
                onChanged: saving
                    ? null
                    : (_) => setState(
                        () => selected.contains(package)
                            ? selected.remove(package)
                            : selected.add(package),
                      ),
              ),
            CircleAvatar(
              backgroundColor: colors.secondaryContainer,
              child: icons[package] == null
                  ? Text(
                      (app['name'] as String).characters
                          .take(1)
                          .toString()
                          .toUpperCase(),
                      style: TextStyle(color: colors.onSecondaryContainer),
                    )
                  : Image.memory(
                      icons[package]!,
                      width: 28,
                      height: 28,
                      cacheWidth: 56,
                      cacheHeight: 56,
                      errorBuilder: (_, _, _) => const Icon(Icons.apps),
                    ),
            ),
          ],
        ),
      ),
      title: Text(
        app['name'] as String,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(detail(app), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: multiple
          ? null
          : PopupMenuButton<String>(
              initialValue: mode,
              tooltip: c.tr('選擇分流方式', 'Choose routing'),
              onSelected: saving ? null : (value) => _setMode(package, value),
              itemBuilder: (context) => [
                for (final value in const ['proxy', 'direct', 'exclude'])
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        Icon(switch (value) {
                          'direct' => Icons.call_split,
                          'exclude' => Icons.block,
                          _ => Icons.vpn_lock,
                        }, size: 20),
                        const SizedBox(width: 12),
                        Text(label(value)),
                        if (value == mode) ...[
                          const Spacer(),
                          const Icon(Icons.check, size: 18),
                        ],
                      ],
                    ),
                  ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: mode == 'proxy'
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label(mode)),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
    );
  }
}
