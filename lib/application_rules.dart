import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'proxy_browser.dart';
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

Future<List<Json>> _loadApplications(AppController c) async =>
    (await c.backend.call('listApplications') as List).map((entry) {
      final app = Map<String, dynamic>.from(entry as Map);
      final icon = app['icon'];
      if (icon is String && icon.isNotEmpty && icon.length <= 45000) {
        try {
          app['iconBytes'] = base64Decode(icon);
        } on FormatException {
          /* Fall back to initials. */
        }
      }
      return app;
    }).toList();

String _pathKey(String path) => Platform.isWindows ? path.toLowerCase() : path;

class _ApplicationAvatar extends StatelessWidget {
  const _ApplicationAvatar(this.app);
  final Json app;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = app['name'] as String? ?? '?';
    final bytes = app['iconBytes'] as Uint8List?;
    final initials = Text(
      name.characters.take(1).toString().toUpperCase(),
      style: TextStyle(color: colors.onSecondaryContainer),
    );
    return CircleAvatar(
      backgroundColor: colors.secondaryContainer,
      child: bytes == null
          ? initials
          : Image.memory(
              bytes,
              width: 32,
              height: 32,
              cacheWidth: 64,
              cacheHeight: 64,
              errorBuilder: (_, _, _) => initials,
            ),
    );
  }
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
  List<Json> applications = [];
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    profileId = c.active!.id;
    _loadApplications(c).then(
      (value) {
        if (mounted) setState(() => applications = value);
      },
      onError: (Object _) {
        /* Existing rules remain editable offline. */
      },
    );
  }

  Json applicationFor(_ApplicationRule rule) =>
      applications
          .where(
            (app) => rule.kind == 'PROCESS-PATH'
                ? _pathKey(app['path'] as String) == _pathKey(rule.match)
                : (app['path'] as String).split(RegExp(r'[/\\]')).last ==
                      rule.match,
          )
          .firstOrNull ??
      {'name': rule.name, 'path': rule.match};

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
        application: applicationFor(rule)['name'] as String,
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
      builder: (_) => _ApplicationPicker(c: c, initial: applications),
    );
    if (app == null || !mounted) return;
    final path = app['path'] as String;
    if (!applications.any(
      (item) => _pathKey(item['path'] as String) == _pathKey(path),
    )) {
      setState(() => applications = [...applications, app]);
    }
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
                        final app = applicationFor(rule);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              _ApplicationAvatar(app),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      app['name'] as String,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Tooltip(
                                      message: '${rule.kind}: ${rule.match}',
                                      child: Text(
                                        rule.kind == 'PROCESS-NAME'
                                            ? c.tr(
                                                '依程式名稱比對',
                                                'Match by executable name',
                                              )
                                            : c.tr(
                                                '依此應用程式分流',
                                                'Route this application',
                                              ),
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
    this.proxy,
  });
  final String name, detail, category;
  final String? target, provider;
  final Map? proxy;
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
  String? browsingGroup;
  ProxySort sort = ProxySort.configuration;
  bool list = false, measuring = false, cancelled = false;
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
    cancelled = true;
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
          '${group['type']}${now == null ? '' : ' · $now'}',
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
            proxy: node as Map,
          ),
        );
      }
    }
    return result;
  }

  Future<void> measure(List<_Route> routes) async {
    if (measuring) return;
    final profile = c.activeId;
    setState(() {
      measuring = true;
      cancelled = false;
    });
    for (
      var i = 0;
      i < routes.length && !cancelled && c.running && profile == c.activeId;
      i += 4
    ) {
      await Future.wait(
        routes
            .skip(i)
            .take(4)
            .map((r) => c.testNode(r.name, provider: r.provider)),
      );
      if (!mounted) return;
    }
    if (mounted) setState(() => measuring = false);
  }

  List<ProxySection> sections(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    var entries = choices;
    if (browsingGroup != null) {
      final definition = (c.profileDocument?['proxy-groups'] as List? ?? [])
          .where((g) => g['name'] == browsingGroup)
          .firstOrNull;
      final live = (c.proxies[browsingGroup] as Map?)?['all'] as List?;
      final names = (live ?? definition?['proxies'] as List? ?? []).toSet();
      final use =
          (definition?['include-all'] == true ||
                      definition?['include-all-providers'] == true
                  ? providers.keys.toList()
                  : definition?['use'] as List? ?? [])
              .toSet();
      entries = entries
          .where(
            (r) => r.provider == null
                ? names.contains(r.name)
                : use.contains(r.provider) &&
                      (live == null || names.contains(r.name)),
          )
          .toList();
    } else {
      entries = entries
          .where((r) => category == 'all' || category == r.category)
          .toList();
    }
    final buckets = <String, List<_Route>>{};
    for (final route in entries) {
      final bucket = route.provider ?? route.category;
      final title =
          route.provider ??
          switch (bucket) {
            'system' => c.tr('直連／封鎖', 'Direct / Block'),
            'group' => c.tr('代理群組', 'Proxy groups'),
            'node' => c.tr('本機節點', 'Local nodes'),
            _ => bucket,
          };
      if (!'$title ${route.name} ${route.detail}'.toLowerCase().contains(
        query,
      )) {
        continue;
      }
      // Prefixes keep providers named "group" or "node" separate from local sections.
      buckets
          .putIfAbsent(
            route.provider == null ? 'category:$bucket' : 'provider:$bucket',
            () => [],
          )
          .add(route);
    }
    int rank(String id) => switch (id) {
      'category:group' => 0,
      'category:system' => 1,
      'category:node' => 2,
      _ => 3,
    };
    final ordered = buckets.entries.toList()
      ..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    return [
      for (final bucket in ordered)
        ProxySection(
          id: bucket.key,
          title: bucket.key.startsWith('provider:')
              ? bucket.key.substring(9)
              : switch (bucket.key) {
                  'category:system' => c.tr('直連／封鎖', 'Direct / Block'),
                  'category:group' => c.tr('代理群組', 'Proxy groups'),
                  _ => c.tr('本機節點', 'Local nodes'),
                },
          detail: bucket.key == 'category:group'
              ? c.tr(
                  '點卡片跟隨群組；點箭頭挑選其中的節點',
                  'Select a card to follow its group; use the arrow to browse nodes',
                )
              : '',
          onTest: c.running && !measuring && bucket.key != 'category:system'
              ? () => measure(bucket.value)
              : null,
          choices: [
            for (final route in bucket.value)
              ProxyChoice(
                id: route.identity,
                name: route.name,
                detail: route.detail,
                selected: route.identity == widget.current?.identity,
                delay: c.nodeDelay(
                  route.name,
                  provider: route.provider,
                  proxy: route.proxy,
                ),
                testing: c.isTestingNode(route.name, provider: route.provider),
                onSelect: () => Navigator.pop(context, route),
                onTest: c.running && route.category != 'system'
                    ? () => c.testNode(route.name, provider: route.provider)
                    : null,
                onOpen: route.category == 'group'
                    ? () => setState(() {
                        browsingGroup = route.name;
                        search.clear();
                      })
                    : null,
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) => AlertDialog(
        title: Text(c.tr('選擇出口', 'Choose route')),
        content: SizedBox(
          width: 900,
          height: MediaQuery.sizeOf(context).height * .68,
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
              const SizedBox(height: 8),
              if (browsingGroup != null)
                TextButton.icon(
                  onPressed: () => setState(() {
                    browsingGroup = null;
                    search.clear();
                  }),
                  icon: const Icon(Icons.arrow_back),
                  label: Text('${c.tr('所有出口', 'All routes')} / $browsingGroup'),
                ),
              ProxyBrowserControls(
                c: c,
                sort: sort,
                list: list,
                onSort: (v) => setState(() => sort = v),
                onLayout: (v) => setState(() => list = v),
              ),
              if (browsingGroup == null)
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
                child: ProxyBrowser(
                  c: c,
                  sections: sections(context),
                  sort: sort,
                  list: list,
                  searching: search.text.trim().isNotEmpty,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (measuring)
            TextButton.icon(
              onPressed: () => setState(() => cancelled = true),
              icon: const Icon(Icons.stop),
              label: Text(c.tr('停止測速', 'Stop testing')),
            ),
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
      ),
    );
  }
}

class _ApplicationPicker extends StatefulWidget {
  const _ApplicationPicker({required this.c, this.initial = const []});
  final AppController c;
  final List<Json> initial;
  @override
  State<_ApplicationPicker> createState() => _ApplicationPickerState();
}

class _ApplicationPickerState extends State<_ApplicationPicker> {
  final search = TextEditingController();
  late Future<List<Json>> applications = widget.initial.isEmpty
      ? load()
      : Future.value(widget.initial);
  String category = 'apps';
  AppController get c => widget.c;
  Future<List<Json>> load() => _loadApplications(c);

  List<Json> filtered(List<Json> apps) {
    final query = search.text.trim().toLowerCase();
    return apps.where((app) {
      if (category == 'apps' && app['background'] == true) return false;
      if (category == 'running' && app['running'] == false) return false;
      return '${app['name']} ${app['path']}'.toLowerCase().contains(query);
    }).toList()..sort((a, b) {
      final running =
          (b['running'] == true ? 1 : 0) - (a['running'] == true ? 1 : 0);
      return running != 0
          ? running
          : (a['name'] as String).toLowerCase().compareTo(
              (b['name'] as String).toLowerCase(),
            );
    });
  }

  String status(Json app) => app['running'] == true
      ? c.tr('正在執行', 'Running')
      : app['installed'] == true
      ? c.tr('已安裝・不必先開啟', 'Installed · no need to launch')
      : c.tr('應用程式', 'Application');

  Future<void> details(Json app) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          _ApplicationAvatar(app),
          const SizedBox(width: 12),
          Expanded(child: Text(app['name'] as String)),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status(app)),
            const SizedBox(height: 16),
            Text(
              c.tr('比對的執行檔', 'Executable used for matching'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SelectableText(app['path'] as String),
            const SizedBox(height: 16),
            Text(
              c.tr(
                '此規則適用於使用這個執行檔的新連線。若應用程式另有網路輔助程序，可從「所有程序」加入。',
                'This rule applies to new connections from this executable. Add separate network helpers from All processes if needed.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(c.tr('關閉', 'Close')),
        ),
      ],
    ),
  );
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
      width: 700,
      height: MediaQuery.sizeOf(context).height * .58,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.tr(
              '選擇程式，下一步決定它走哪個出口。',
              'Choose an app, then choose where its traffic goes.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('application-search'),
            autofocus: true,
            controller: search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) async {
              try {
                final entries = filtered(await applications);
                if (mounted && entries.length == 1) {
                  Navigator.pop(this.context, entries.single);
                }
              } catch (_) {
                /* Retry and browsing remain available. */
              }
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: c.tr('搜尋應用程式名稱', 'Search applications'),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: c.tr('清除搜尋', 'Clear search'),
                      onPressed: () => setState(search.clear),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in {
                'apps': c.tr('應用程式', 'Applications'),
                'running': c.tr('正在執行', 'Running'),
                'all': c.tr('所有程序', 'All processes'),
              }.entries)
                ChoiceChip(
                  key: ValueKey('application-filter-${item.key}'),
                  label: Text(item.value),
                  selected: category == item.key,
                  onSelected: (_) => setState(() => category = item.key),
                ),
            ],
          ),
          const SizedBox(height: 8),
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
                final entries = filtered(snapshot.data!);
                if (entries.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.search_off, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          c.tr(
                            '找不到程式？先開啟它，再重新整理。',
                            'App missing? Open it, then refresh.',
                          ),
                        ),
                        if (category != 'all')
                          TextButton(
                            onPressed: () => setState(() => category = 'all'),
                            child: Text(c.tr('搜尋所有程序', 'Search all processes')),
                          ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final app = entries[index];
                    return ListTile(
                      key: ValueKey('application:${app['path']}'),
                      leading: _ApplicationAvatar(app),
                      title: Text(
                        app['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${status(app)} · ${(app['path'] as String).split(RegExp(r'[/\\]')).last}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.info_outline),
                        tooltip: c.tr('查看應用程式詳細資訊', 'Application details'),
                        onPressed: () => details(app),
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
