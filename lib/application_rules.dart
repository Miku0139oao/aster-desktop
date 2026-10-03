import 'dart:io';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'dialogs.dart' show selectApplicationExecutable;

Future<void> showApplicationRouting(BuildContext context, AppController c) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ApplicationRouting(c: c),
    );

class _ApplicationRule {
  _ApplicationRule(this.raw, this.kind, this.match, this.target);
  final String raw, kind, match, target;
  String get name => match.split(RegExp(r'[/\\]')).last;
}

class _ApplicationRouting extends StatefulWidget {
  const _ApplicationRouting({required this.c});
  final AppController c;
  @override
  State<_ApplicationRouting> createState() => _ApplicationRoutingState();
}

class _ApplicationRoutingState extends State<_ApplicationRouting> {
  late final String profileId;
  bool working = false;
  String? error;
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    profileId = c.active!.id;
  }

  List<_ApplicationRule> get rules {
    final result = <_ApplicationRule>[];
    for (final raw in c.profileDocument?['rules'] as List? ?? []) {
      if (raw is! String) continue;
      final parts = raw.split(',');
      if (parts.length == 3 && parts.first.startsWith('PROCESS-')) {
        result.add(_ApplicationRule(raw, parts[0], parts[1], parts[2]));
      }
    }
    return result;
  }

  _Route currentRoute(String target) {
    for (final raw in c.active!.json['desktopProviderRoutes'] as List? ?? []) {
      if (raw['group'] == target) {
        return _Route(
          raw['node'],
          c.tr('訂閱節點', 'Provider node'),
          provider: raw['provider'],
          target: target,
        );
      }
    }
    return _Route(
      target,
      target == 'DIRECT'
          ? c.tr('直連', 'Direct')
          : target == 'REJECT'
          ? c.tr('封鎖', 'Block')
          : c.tr('出口', 'Route'),
      target: target,
    );
  }

  Future<void> change(_ApplicationRule rule) async {
    final route = await showDialog<_Route>(
      context: context,
      builder: (_) => _RoutePicker(
        c: c,
        application: rule.name,
        current: currentRoute(rule.target),
      ),
    );
    if (route == null || !mounted) return;
    await save(
      route: route,
      kind: rule.kind,
      match: rule.match,
      remove: rule.raw,
    );
  }

  Future<void> save({
    String? rule,
    String? remove,
    _Route? route,
    String? kind,
    String? match,
  }) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (c.activeId != profileId) {
        throw BackendException(
          c.tr(
            '目前設定已變更，請重新開啟應用程式分流。',
            'The active profile changed. Reopen application routing.',
          ),
        );
      }
      await c.backend.call('patchProfile', {
        'id': profileId,
        'rule': ?(route != null && route.provider == null
            ? '$kind,$match,${route.target}'
            : rule),
        if (route?.provider != null)
          'providerRoute': {
            'kind': kind,
            'match': match,
            'provider': route!.provider,
            'node': route.name,
          },
        'removeRule': ?remove,
      });
      await c.refresh();
      if (c.running) await c.loadRuntime();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> add() async {
    final app = await showDialog<Json>(
      context: context,
      builder: (_) => _ApplicationPicker(c: c),
    );
    if (app == null || !mounted) return;
    final path = app['path'] as String;
    final name = app['name'] as String;
    final selected = await showDialog<_Route>(
      context: context,
      builder: (_) => _RoutePicker(c: c, application: name),
    );
    if (selected == null || !mounted) return;
    if (path.contains(',') || path.contains('\n') || path.contains('\r')) {
      setState(
        () => error = c.tr(
          '此路徑含核心規則無法表示的字元。',
          'This path contains a character unsupported by core routing rules.',
        ),
      );
      return;
    }
    final existing = rules
        .where(
          (rule) =>
              rule.kind == 'PROCESS-PATH' &&
              (Platform.isWindows
                  ? rule.match.toLowerCase() == path.toLowerCase()
                  : rule.match == path),
        )
        .firstOrNull;
    await save(
      route: selected,
      kind: 'PROCESS-PATH',
      match: path,
      remove: existing?.raw,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = rules;
    return AlertDialog(
      title: Text(c.tr('應用程式分流', 'Application routing')),
      content: SizedBox(
        width: 760,
        height: MediaQuery.sizeOf(context).height * .62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.tr(
                '選擇應用程式，直接管理它的出口。使用「代理所有應用程式」及規則模式；變更適用於新連線，訂閱更新會保留規則。',
                'Choose an application and manage its route. Use Proxy all applications and Rule mode. Changes apply to new connections; subscription updates retain these rules.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: working ? null : add,
              icon: const Icon(Icons.add),
              label: Text(c.tr('新增應用程式', 'Add application')),
            ),
            const SizedBox(height: 12),
            if (working) const LinearProgressIndicator(),
            if (error != null)
              ExpansionTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  c.tr(
                    '未能儲存，原設定已保留。',
                    'Could not save; previous configuration retained.',
                  ),
                ),
                children: [SelectableText(error!)],
              ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        c.tr('尚未設定應用程式規則', 'No application rules yet'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final rule = entries[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.apps),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rule.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Tooltip(
                                      message: '${rule.kind}: ${rule.match}',
                                      child: Text(
                                        rule.match,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 230,
                                child: OutlinedButton.icon(
                                  key: ValueKey('application-route-$index'),
                                  onPressed: working
                                      ? null
                                      : () => change(rule),
                                  icon: const Icon(Icons.swap_horiz),
                                  label: Text(
                                    currentRoute(rule.target).name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: ValueKey('remove-application-rule-$index'),
                                tooltip: c.tr('刪除規則', 'Remove rule'),
                                onPressed: working
                                    ? null
                                    : () => save(remove: rule.raw),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Text(
              c.tr(
                '使用另一個執行檔的輔助程式，可另外從清單加入。完整規則仍可在 YAML 編輯器調整。',
                'Helpers using another executable can be added from the list. Full rules remain editable in YAML.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(c.tr('完成', 'Done')),
        ),
      ],
    );
  }
}

class _Route {
  _Route(
    this.name,
    this.detail, {
    this.target,
    this.provider,
    this.category = 'node',
  });
  final String name, detail, category;
  final String? target, provider;
  String get identity =>
      provider == null ? 'target:$target' : 'provider:$provider:$name';
}

class _RoutePicker extends StatefulWidget {
  const _RoutePicker({
    required this.c,
    required this.application,
    this.current,
  });
  final AppController c;
  final String application;
  final _Route? current;
  @override
  State<_RoutePicker> createState() => _RoutePickerState();
}

class _RoutePickerState extends State<_RoutePicker> {
  final search = TextEditingController();
  String category = 'all';
  bool loading = false;
  String? error;
  Json providers = {};
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!c.running) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await c.api('GET', '/providers/proxies') as Json;
      if (mounted) {
        setState(() => providers = result['providers'] as Json? ?? {});
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<_Route> get choices {
    final doc = c.profileDocument;
    final result = <_Route>[
      _Route(
        'DIRECT',
        c.tr('直連', 'Direct'),
        target: 'DIRECT',
        category: 'system',
      ),
      _Route(
        'REJECT',
        c.tr('封鎖', 'Block'),
        target: 'REJECT',
        category: 'system',
      ),
    ];
    final managed = (c.active!.json['desktopProviderRoutes'] as List? ?? [])
        .map((r) => r['group'])
        .toSet();
    for (final group in doc?['proxy-groups'] as List? ?? []) {
      final name = group['name'] as String;
      if (managed.contains(name)) continue;
      final now = (c.proxies[name] as Json?)?['now'];
      result.add(
        _Route(
          name,
          '${c.tr('代理群組', 'Group')} · ${group['type']}${now == null ? '' : ' · $now'}',
          target: name,
          category: 'group',
        ),
      );
    }
    for (final node in doc?['proxies'] as List? ?? []) {
      result.add(
        _Route(
          node['name'],
          '${c.tr('節點', 'Node')} · ${node['type']}',
          target: node['name'],
        ),
      );
    }
    final definitions = doc?['proxy-providers'] as Map? ?? {};
    for (final entry in definitions.entries) {
      final live = (providers[entry.key] as Json?)?['proxies'] as List?;
      final nodes = live ?? entry.value['payload'] as List? ?? [];
      for (final node in nodes) {
        result.add(
          _Route(
            node['name'],
            '${c.tr('訂閱節點', 'Provider node')} · ${entry.key} · ${node['type']}',
            provider: entry.key,
          ),
        );
      }
    }
    final query = search.text.toLowerCase();
    return result
        .where(
          (r) =>
              (category == 'all' || category == r.category) &&
              '${r.name} ${r.detail}'.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final entries = choices;
    return AlertDialog(
      title: Text(c.tr('選擇出口', 'Choose route')),
      content: SizedBox(
        width: 680,
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.application,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('route-search'),
              controller: search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: c.tr('搜尋群組或節點', 'Search groups or nodes'),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final item in {
                  'all': c.tr('全部', 'All'),
                  'group': c.tr('群組', 'Groups'),
                  'node': c.tr('節點', 'Nodes'),
                  'system': c.tr('直連／封鎖', 'Direct / Block'),
                }.entries)
                  ChoiceChip(
                    label: Text(item.value),
                    selected: category == item.key,
                    onSelected: (_) => setState(() => category = item.key),
                  ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (!c.running &&
                (c.profileDocument?['proxy-providers'] as Map? ?? {})
                    .isNotEmpty)
              Text(
                c.tr(
                  '連線後可載入遠端訂閱的節點，現在仍可選群組。',
                  'Connect to load remote provider nodes. Groups are available now.',
                ),
              ),
            if (error != null)
              ExpansionTile(
                title: Text(
                  c.tr('訂閱節點未載入，可重試', 'Provider nodes could not load. Retry'),
                ),
                children: [SelectableText(error!)],
              ),
            Expanded(
              child: entries.isEmpty
                  ? Center(child: Text(c.tr('沒有符合的出口', 'No matching routes')))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final route = entries[index];
                        final selected =
                            route.identity == widget.current?.identity;
                        return ListTile(
                          key: ValueKey(route.identity),
                          leading: Icon(
                            route.category == 'group'
                                ? Icons.hub_outlined
                                : route.name == 'REJECT'
                                ? Icons.block
                                : route.name == 'DIRECT'
                                ? Icons.public
                                : Icons.dns_outlined,
                          ),
                          title: Text(
                            route.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            route.detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? const Icon(Icons.check_circle)
                              : null,
                          selected: selected,
                          onTap: () => Navigator.pop(context, route),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (c.running)
          TextButton.icon(
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
            label: Text(c.tr('重新整理', 'Refresh')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(c.tr('取消', 'Cancel')),
        ),
      ],
    );
  }
}

class _ApplicationPicker extends StatefulWidget {
  const _ApplicationPicker({required this.c});
  final AppController c;
  @override
  State<_ApplicationPicker> createState() => _ApplicationPickerState();
}

class _ApplicationPickerState extends State<_ApplicationPicker> {
  final search = TextEditingController();
  late Future<List<Json>> applications = load();
  AppController get c => widget.c;
  Future<List<Json>> load() async =>
      (await c.backend.call('listApplications') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> browse() async {
    try {
      final path = await selectApplicationExecutable();
      if (path != null && mounted) {
        Navigator.pop(context, {
          'name': path.split(RegExp(r'[/\\]')).last,
          'path': path,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(c.tr('選擇應用程式', 'Choose application')),
    content: SizedBox(
      width: 620,
      height: MediaQuery.sizeOf(context).height * .5,
      child: Column(
        children: [
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: c.tr('搜尋正在執行的應用程式', 'Search running applications'),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<Json>>(
              future: applications,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: TextButton(
                      onPressed: () => setState(() => applications = load()),
                      child: Text(
                        c.tr('無法取得清單，重試', 'Could not load applications. Retry'),
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final query = search.text.toLowerCase();
                final entries = snapshot.data!
                    .where(
                      (e) => '${e['name']} ${e['path']}'.toLowerCase().contains(
                        query,
                      ),
                    )
                    .toList();
                if (entries.isEmpty) {
                  return Center(
                    child: Text(
                      c.tr(
                        '沒有符合的應用程式；可先啟動它，或選擇執行檔。',
                        'No matching applications. Start the application or choose its executable.',
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final app = entries[index];
                    return ListTile(
                      leading: const Icon(Icons.apps),
                      title: Text(app['name'] as String),
                      subtitle: Text(
                        app['path'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, app),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(c.tr('取消', 'Cancel')),
      ),
      OutlinedButton.icon(
        onPressed: () => setState(() => applications = load()),
        icon: const Icon(Icons.refresh),
        label: Text(c.tr('重新整理', 'Refresh')),
      ),
      FilledButton.icon(
        onPressed: browse,
        icon: const Icon(Icons.folder_open),
        label: Text(c.tr('選擇其他應用程式', 'Choose another application')),
      ),
    ],
  );
}
