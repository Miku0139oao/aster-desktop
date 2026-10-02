import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';

import 'backend.dart';
import 'controller.dart';
import 'dialogs.dart';
export 'dialogs.dart' show showImportDialog;

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
    children: children,
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = 24});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class EmptyMessage extends StatelessWidget {
  const EmptyMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });
  final IconData icon;
  final String title, detail;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              detail,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    ),
  );
}

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasProfile = c.active != null;
    return PageBody(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: [cs.primaryContainer, cs.secondaryContainer],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      c.running
                          ? Icons.verified_user_outlined
                          : Icons.shield_outlined,
                      size: 30,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.running
                              ? c.tr('已連線', 'Connected')
                              : hasProfile
                              ? c.tr('準備好連線', 'Ready to connect')
                              : c.tr('從一份訂閱開始', 'Start with a subscription'),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cs.onPrimaryContainer,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          c.running
                              ? c.tr('你的代理已啟動。', 'Your proxy is active.')
                              : hasProfile
                              ? c.tr(
                                  '按一下，就能開始使用。',
                                  'One click and you are ready.',
                                )
                              : c.tr(
                                  '貼上訂閱網址，或匯入已有的設定。',
                                  'Paste a subscription URL or import a configuration.',
                                ),
                          style: TextStyle(color: cs.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('primary-connect'),
                    onPressed: c.busy
                        ? null
                        : () => hasProfile
                              ? c.toggle()
                              : showImportDialog(context, c),
                    icon: Icon(
                      !hasProfile
                          ? Icons.add
                          : c.running
                          ? Icons.power_settings_new
                          : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      !hasProfile
                          ? c.tr('匯入訂閱或設定', 'Import a subscription')
                          : c.running
                          ? c.tr('停止代理', 'Disconnect')
                          : c.tr('開始連線', 'Connect'),
                    ),
                  ),
                  if (hasProfile)
                    Text(
                      c.active!.name,
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (!hasProfile)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle(c.tr('三步開始使用', 'Three steps to get connected')),
                for (final step in [
                  (
                    Icons.add_link,
                    c.tr('1. 匯入', '1. Import'),
                    c.tr(
                      '訂閱網址、設定檔或節點分享連結。',
                      'A subscription URL, configuration file, or node links.',
                    ),
                  ),
                  (
                    Icons.hub_outlined,
                    c.tr('2. 選擇節點', '2. Choose a node'),
                    c.tr(
                      '可以先用自動選擇，之後隨時更換。',
                      'Start with automatic selection and switch whenever you like.',
                    ),
                  ),
                  (
                    Icons.check_circle_outline,
                    c.tr('3. 連線', '3. Connect'),
                    c.tr(
                      '系統代理會自動設定，不需要終端。',
                      'The system proxy is set up for you. No terminal needed.',
                    ),
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Icon(step.$1, color: cs.primary),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                step.$2,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                step.$3,
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _stat(
                context,
                Icons.arrow_downward,
                c.tr('下載速度', 'Download'),
                c.running ? '${bytes(c.download)}/s' : '—',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _stat(
                context,
                Icons.arrow_upward,
                c.tr('上傳速度', 'Upload'),
                c.running ? '${bytes(c.upload)}/s' : '—',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _stat(
                context,
                Icons.swap_calls,
                c.tr('活動連線', 'Connections'),
                c.running
                    ? '${(c.connections['connections'] as List? ?? []).length}'
                    : '—',
              ),
            ),
          ],
        ),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(c.tr('連線方式', 'Connection settings')),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(c.tr('系統代理', 'System proxy')),
                subtitle: Text(
                  c.tr(
                    '讓支援系統代理的應用程式自動連線。',
                    'Connect applications that follow system proxy settings.',
                  ),
                ),
                value: c.settings.systemProxy,
                onChanged: c.busy || c.running
                    ? null
                    : (v) => c.saveSettings({'systemProxy': v}),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(c.tr('代理所有應用程式', 'Proxy all applications')),
                subtitle: Text(
                  c.tr(
                    '使用 TUN，需要一次性的系統授權。',
                    'Uses TUN and requires system approval once.',
                  ),
                ),
                value: c.settings.tun,
                onChanged: c.busy || c.running
                    ? null
                    : (v) => c.saveSettings({'tun': v}),
              ),
              const Divider(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final mode in [
                    ('rule', c.tr('依規則', 'Rules')),
                    ('global', c.tr('全部代理', 'Global')),
                    ('direct', c.tr('全部直連', 'Direct')),
                  ])
                    ChoiceChip(
                      label: Text(mode.$2),
                      selected: c.settings.mode == mode.$1,
                      onSelected: c.busy
                          ? null
                          : (_) => c.saveSettings({'mode': mode.$1}),
                    ),
                ],
              ),
              if (c.running)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    c.tr(
                      '要更改連線方式，請先停止代理。',
                      'Disconnect before changing how applications connect.',
                    ),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        if (hasProfile)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle(
                  c.tr('目前設定', 'Current configuration'),
                  action: TextButton(
                    onPressed: () => c.navigate(2),
                    child: Text(c.tr('管理', 'Manage')),
                  ),
                ),
                Text(
                  c.active!.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  c.active!.url.isEmpty
                      ? c.tr('本機設定', 'Local configuration')
                      : c.tr(
                          '已連結訂閱，可隨時更新。',
                          'Subscription linked. Refresh whenever you need.',
                        ),
                ),
                if (c.coreVersion.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Aster Core · ${c.coreVersion}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _stat(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => Panel(
    padding: 18,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class NodesPage extends StatefulWidget {
  const NodesPage({super.key, required this.c});
  final AppController c;
  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  String search = '', group = '';
  bool measuring = false, cancelled = false;
  AppController get c => widget.c;
  Json _offline() {
    try {
      final doc = loadYaml(c.active?.content ?? '') as YamlMap;
      final result = <String, dynamic>{};
      for (final node in (doc['proxies'] as YamlList? ?? [])) {
        result[node['name'] as String] = {
          'name': node['name'],
          'type': node['type'],
        };
      }
      for (final g in (doc['proxy-groups'] as YamlList? ?? [])) {
        result[g['name'] as String] = {
          'name': g['name'],
          'type': g['type'] == 'select' ? 'Selector' : g['type'],
          'all': List<String>.from(g['proxies'] as List? ?? []),
        };
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _measure(List<String> nodes) async {
    setState(() {
      measuring = true;
      cancelled = false;
    });
    for (var i = 0; i < nodes.length && !cancelled; i += 4) {
      await Future.wait(nodes.skip(i).take(4).map(c.testNode));
      if (!mounted) return;
    }
    if (mounted) setState(() => measuring = false);
  }

  @override
  Widget build(BuildContext context) {
    final all = c.running ? c.proxies : _offline();
    final groups = all.entries
        .where((e) => (e.value as Json)['all'] is List)
        .toList();
    if (groups.isEmpty) {
      return EmptyMessage(
        icon: Icons.hub_outlined,
        title: c.tr('還沒有可選擇的節點', 'No nodes to choose yet'),
        detail: c.tr(
          '先匯入訂閱；連線後會顯示提供者的完整節點。',
          'Import a subscription. Provider nodes appear after connecting.',
        ),
        action: FilledButton(
          onPressed: () => showImportDialog(context, c),
          child: Text(c.tr('匯入', 'Import')),
        ),
      );
    }
    if (!groups.any((g) => g.key == group)) group = groups.first.key;
    final selected = all[group] as Json;
    final nodes = (selected['all'] as List)
        .cast<String>()
        .where((name) => name.toLowerCase().contains(search.toLowerCase()))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: group,
                  decoration: InputDecoration(
                    labelText: c.tr('代理群組', 'Proxy group'),
                  ),
                  items: groups
                      .map(
                        (g) => DropdownMenuItem(
                          value: g.key,
                          child: Text(g.key, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => group = v!),
                ),
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  onChanged: (v) => setState(() => search = v),
                  decoration: InputDecoration(
                    hintText: c.tr('搜尋節點', 'Search nodes'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: !c.running
                    ? null
                    : measuring
                    ? () => setState(() => cancelled = true)
                    : () => _measure(nodes),
                icon: Icon(measuring ? Icons.stop : Icons.speed),
                label: Text(
                  measuring
                      ? c.tr('停止測速', 'Stop testing')
                      : c.tr('測試延遲', 'Test latency'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (!c.running)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
            child: Text(
              c.tr(
                '開始連線後，即可切換節點與測速。',
                'Connect to switch nodes and test latency.',
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
            itemCount: nodes.length,
            itemBuilder: (context, i) {
              final name = nodes[i];
              final node = all[name] as Json? ?? {};
              final chosen = selected['now'] == name;
              final history = node['history'] as List? ?? [];
              final delay = history.isEmpty
                  ? null
                  : (history.last as Json)['delay'];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: chosen
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  leading: Icon(
                    chosen ? Icons.check_circle : Icons.circle_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(name),
                  subtitle: Text(node['type'] as String? ?? ''),
                  onTap: !c.running || c.busy || selected['type'] != 'Selector'
                      ? null
                      : () => c.selectNode(group, name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (delay != null)
                        Text(delay == 0 ? c.tr('逾時', 'Timeout') : '$delay ms'),
                      IconButton(
                        tooltip: c.tr('測試此節點', 'Test this node'),
                        onPressed: !c.running || measuring
                            ? null
                            : () => c.testNode(name),
                        icon: const Icon(Icons.speed),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }
}

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              c.tr('訂閱與本機設定', 'Subscriptions and local configurations'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          FilledButton.icon(
            onPressed: c.busy ? null : () => showImportDialog(context, c),
            icon: const Icon(Icons.add),
            label: Text(c.tr('匯入', 'Import')),
          ),
        ],
      ),
      const SizedBox(height: 20),
      if (c.profiles.isEmpty)
        EmptyMessage(
          icon: Icons.folder_open,
          title: c.tr('尚未匯入設定', 'No configurations yet'),
          detail: c.tr(
            '支援 Clash YAML 與常見節點分享連結。',
            'Supports Clash YAML and common node links.',
          ),
        ),
      for (final p in c.profiles)
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    p.id == c.activeId
                        ? Icons.check_circle
                        : Icons.folder_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      p.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (p.id == c.activeId)
                    Chip(label: Text(c.tr('使用中', 'Active'))),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                p.url.isEmpty
                    ? c.tr('本機設定', 'Local configuration')
                    : Uri.tryParse(p.url)?.host ?? c.tr('訂閱', 'Subscription'),
              ),
              if (p.updated != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${c.tr('更新於', 'Updated')} ${p.updated!.toLocal().toString().split('.').first}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if ((p.json['usage'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(subscriptionUsage(p.json['usage'] as String, c)),
                ),
              if (p.warnings.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    c.tr('部分節點未能匯入', 'Some nodes could not be imported'),
                  ),
                  children: p.warnings
                      .map((w) => ListTile(title: Text(w)))
                      .toList(),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (p.id != c.activeId)
                    FilledButton.tonal(
                      onPressed: c.busy
                          ? null
                          : () => c.perform(() async {
                              await c.backend.call('activate', {'id': p.id});
                            }),
                      child: Text(c.tr('使用此設定', 'Use configuration')),
                    ),
                  if (p.url.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: c.busy
                          ? null
                          : () => c.perform(() async {
                              await c.backend.call('refresh', {'id': p.id});
                            }),
                      icon: const Icon(Icons.refresh),
                      label: Text(c.tr('更新訂閱', 'Refresh')),
                    ),
                  TextButton.icon(
                    onPressed: c.busy
                        ? null
                        : () => showYamlEditor(context, c, p),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(c.tr('編輯設定', 'Edit')),
                  ),
                  TextButton.icon(
                    onPressed: c.busy
                        ? null
                        : () => exportText(
                            context,
                            c,
                            p.content,
                            '${p.name}.yaml',
                          ),
                    icon: const Icon(Icons.save_alt),
                    label: Text(c.tr('匯出', 'Export')),
                  ),
                  TextButton.icon(
                    onPressed: c.busy
                        ? null
                        : () async {
                            if (await confirm(
                              context,
                              c,
                              c.tr('刪除這份設定？', 'Delete this configuration?'),
                            )) {
                              await c.perform(() async {
                                await c.backend.call('deleteProfile', {
                                  'id': p.id,
                                });
                              });
                            }
                          },
                    icon: const Icon(Icons.delete_outline),
                    label: Text(c.tr('刪除', 'Delete')),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}

String subscriptionUsage(String raw, AppController c) {
  final values = <String, num>{};
  for (final part in raw.split(';')) {
    final pair = part.trim().split('=');
    if (pair.length == 2) {
      values[pair[0]] = num.tryParse(pair[1]) ?? 0;
    }
  }
  final used = (values['upload'] ?? 0) + (values['download'] ?? 0);
  final total = values['total'] ?? 0;
  var text =
      '${c.tr('已用', 'Used')} ${bytes(used)}${total > 0 ? ' / ${bytes(total)}' : ''}';
  final expire = values['expire'] ?? 0;
  if (expire > 0) {
    text +=
        ' · ${c.tr('到期', 'Expires')} ${DateTime.fromMillisecondsSinceEpoch(expire.toInt() * 1000).toLocal().toString().split(' ').first}';
  }
  return text;
}

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.c});
  final AppController c;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  String search = '';
  AppController get c => widget.c;
  @override
  Widget build(BuildContext context) {
    if (!c.running) {
      return EmptyMessage(
        icon: Icons.swap_calls,
        title: c.tr('連線後查看活動連線', 'View activity after connecting'),
        detail: c.tr(
          '這裡會顯示應用程式、目的地與命中的規則。',
          'See applications, destinations, and matched rules here.',
        ),
      );
    }
    final entries = (c.connections['connections'] as List? ?? [])
        .cast<Json>()
        .where((e) => e.toString().toLowerCase().contains(search.toLowerCase()))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: c.tr(
                      '搜尋應用程式、網域或 IP',
                      'Search application, domain, or IP',
                    ),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => search = v),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: c.busy || entries.isEmpty
                    ? null
                    : () async {
                        if (await confirm(
                          context,
                          c,
                          c.tr(
                            '中止目前顯示的連線？',
                            'Close the displayed connections?',
                          ),
                        )) {
                          await c.perform(() async {
                            for (var i = 0; i < entries.length; i += 8) {
                              await Future.wait(
                                entries
                                    .skip(i)
                                    .take(8)
                                    .map(
                                      (e) => c.api(
                                        'DELETE',
                                        '/connections/${Uri.encodeComponent(e['id'] as String)}',
                                      ),
                                    ),
                              );
                            }
                          });
                        }
                      },
                child: Text(c.tr('中止顯示連線', 'Close displayed')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: entries.isEmpty
              ? EmptyMessage(
                  icon: Icons.check_circle_outline,
                  title: c.tr('目前沒有活動連線', 'No active connections'),
                  detail: c.tr(
                    '使用瀏覽器或其他應用程式後，連線會出現在這裡。',
                    'Connections appear when you use your applications.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final metadata = e['metadata'] as Json? ?? {};
                    final host = (metadata['host'] as String? ?? '').isNotEmpty
                        ? metadata['host']
                        : metadata['destinationIP'];
                    final process =
                        metadata['process'] ??
                        metadata['processPath'] ??
                        metadata['network'] ??
                        '';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ExpansionTile(
                        leading: const Icon(Icons.language),
                        title: Text(
                          '$host:${metadata['destinationPort'] ?? ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '$process · ${(e['chains'] as List? ?? []).join(' → ')}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: c.tr('中止連線', 'Close connection'),
                          onPressed: c.busy
                              ? null
                              : () => c.perform(() async {
                                  await c.api(
                                    'DELETE',
                                    '/connections/${Uri.encodeComponent(e['id'] as String)}',
                                  );
                                }),
                          icon: const Icon(Icons.close),
                        ),
                        children: [
                          ListTile(
                            title: Text(
                              '${c.tr('規則', 'Rule')}: ${e['rule'] ?? ''} ${e['rulePayload'] ?? ''}',
                            ),
                            subtitle: Text(
                              '↓ ${bytes(e['download'] as num? ?? 0)}   ↑ ${bytes(e['upload'] as num? ?? 0)}',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.c});
  final AppController c;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String search = '', level = 'all';
  AppController get c => widget.c;
  @override
  Widget build(BuildContext context) {
    final logs = c.logs
        .where(
          (l) =>
              l.toLowerCase().contains(search.toLowerCase()) &&
              (level == 'all' || l.contains('level=$level')),
        )
        .toList()
        .reversed
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  onChanged: (v) => setState(() => search = v),
                  decoration: InputDecoration(
                    hintText: c.tr('搜尋日誌', 'Search logs'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
              ),
              SizedBox(
                width: 160,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: level,
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(c.tr('所有層級', 'All levels')),
                    ),
                    for (final l in ['info', 'warning', 'error', 'debug'])
                      DropdownMenuItem(value: l, child: Text(l)),
                  ],
                  onChanged: (v) => setState(() => level = v!),
                ),
              ),
              OutlinedButton.icon(
                onPressed: logs.isEmpty
                    ? null
                    : () => exportText(
                        context,
                        c,
                        sanitizeLogs(logs.join('\n')),
                        'aster-logs.txt',
                      ),
                icon: const Icon(Icons.download),
                label: Text(c.tr('匯出日誌', 'Export logs')),
              ),
              IconButton(
                tooltip: c.tr('複製日誌', 'Copy logs'),
                onPressed: logs.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: sanitizeLogs(logs.join('\n'))),
                      ),
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: logs.isEmpty
              ? EmptyMessage(
                  icon: Icons.receipt_long_outlined,
                  title: c.tr('目前沒有日誌', 'No logs yet'),
                  detail: c.tr(
                    '連線後會顯示核心的即時日誌。',
                    'Core logs appear after connecting.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                  itemCount: logs.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: SelectableText(
                      logs[i].replaceAll(RegExp(r'\x1B\[[0-9;]*m'), ''),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: logs[i].contains('level=error')
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

String sanitizeLogs(String value) => value
    .replaceAll(
      RegExp(
        r'(?:ss|vmess|vless|trojan|hy2|hysteria2|tuic|anytls)://\S+',
        caseSensitive: false,
      ),
      '[node link redacted]',
    )
    .replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      'Bearer [redacted]',
    )
    .replaceAllMapped(
      RegExp(
        r'(password|secret|token|private-key)[=:]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}=[redacted]',
    );

class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      Panel(
        child: Column(
          children: [
            SectionTitle(c.tr('外觀與一般設定', 'Appearance and general')),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: c.settings.language,
              decoration: InputDecoration(labelText: c.tr('介面語言', 'Language')),
              items: const [
                DropdownMenuItem(value: 'zh_TW', child: Text('繁體中文')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: c.busy ? null : (v) => c.saveSettings({'language': v}),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: c.settings.theme,
              decoration: InputDecoration(labelText: c.tr('外觀', 'Appearance')),
              items: [
                DropdownMenuItem(
                  value: 'system',
                  child: Text(c.tr('跟隨系統', 'System')),
                ),
                DropdownMenuItem(
                  value: 'light',
                  child: Text(c.tr('淺色', 'Light')),
                ),
                DropdownMenuItem(
                  value: 'dark',
                  child: Text(c.tr('深色', 'Dark')),
                ),
              ],
              onChanged: c.busy ? null : (v) => c.saveSettings({'theme': v}),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(c.tr('登入後自動啟動並連線', 'Start and connect at login')),
              subtitle: Text(
                c.tr('使用目前選擇的設定。', 'Uses the selected configuration.'),
              ),
              value: c.settings.autoStart,
              onChanged: c.busy
                  ? null
                  : (v) => c.saveSettings({'autoStart': v}),
            ),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue:
                  [0, 1, 6, 24, 168].contains(c.settings.subscriptionHours)
                  ? c.settings.subscriptionHours
                  : 24,
              decoration: InputDecoration(
                labelText: c.tr('自動更新訂閱', 'Refresh subscriptions'),
              ),
              items: [
                DropdownMenuItem(
                  value: 0,
                  child: Text(c.tr('僅手動更新', 'Manual only')),
                ),
                for (final h in [1, 6, 24, 168])
                  DropdownMenuItem(
                    value: h,
                    child: Text(c.tr('每 $h 小時', 'Every $h hours')),
                  ),
              ],
              onChanged: c.busy
                  ? null
                  : (v) => c.saveSettings({'subscriptionHours': v}),
            ),
          ],
        ),
      ),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(c.tr('背景服務', 'Background service')),
            Text(
              c.service['installed'] == true
                  ? c.tr(
                      '已安裝；代理所有應用程式時會使用。',
                      'Installed. Used when proxying all applications.',
                    )
                  : c.tr(
                      '安裝後可使用 TUN，主介面維持一般權限。',
                      'Install to use TUN while keeping the interface unprivileged.',
                    ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: c.busy || c.running
                      ? null
                      : () => c.perform(() async {
                          await c.backend.call('installService');
                        }),
                  icon: const Icon(Icons.admin_panel_settings_outlined),
                  label: Text(
                    c.service['installed'] == true
                        ? c.tr('重新安裝／授權', 'Reinstall / authorize')
                        : c.tr('安裝背景服務', 'Install service'),
                  ),
                ),
                if (c.service['installed'] == true)
                  TextButton(
                    onPressed: c.busy || c.running
                        ? null
                        : () => c.perform(() async {
                            await c.backend.call('uninstallService');
                          }),
                    child: Text(c.tr('移除服務', 'Remove service')),
                  ),
              ],
            ),
          ],
        ),
      ),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(c.tr('網路與分流', 'Network and routing')),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(c.tr('允許區域網路使用代理', 'Allow LAN access')),
              subtitle: Text(
                c.tr(
                  '讓其他裝置使用這台電腦的代理連接埠。',
                  'Allow other devices to use this computer’s proxy port.',
                ),
              ),
              value: c.settings.allowLan,
              onChanged: c.busy ? null : (v) => c.saveSettings({'allowLan': v}),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.tr('本機代理連接埠', 'Local proxy port')),
              subtitle: Text('127.0.0.1:${c.settings.mixedPort}'),
              trailing: IconButton(
                tooltip: c.tr('修改連接埠', 'Change port'),
                onPressed: c.busy || c.running
                    ? null
                    : () => showPortDialog(context, c),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: c.busy || c.active == null
                      ? null
                      : () => showDNSDialog(context, c),
                  icon: const Icon(Icons.dns_outlined),
                  label: Text(c.tr('DNS 設定', 'DNS settings')),
                ),
                OutlinedButton.icon(
                  onPressed: c.busy || c.active == null
                      ? null
                      : () => showRuleDialog(context, c),
                  icon: const Icon(Icons.alt_route),
                  label: Text(c.tr('新增分流規則', 'Add routing rule')),
                ),
                OutlinedButton.icon(
                  onPressed: c.busy || c.active == null
                      ? null
                      : () => showYamlEditor(context, c, c.active!),
                  icon: const Icon(Icons.code),
                  label: Text(c.tr('編輯完整 YAML', 'Edit full YAML')),
                ),
              ],
            ),
            if (c.rules.isNotEmpty) ...[
              const SizedBox(height: 20),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(c.tr('檢視目前規則', 'Current rules')),
                children: [
                  SizedBox(
                    height: 240,
                    child: ListView.builder(
                      itemCount: c.rules.length,
                      itemBuilder: (context, i) {
                        final r = c.rules[i];
                        return ListTile(
                          dense: true,
                          title: Text('${r['type']} · ${r['payload']}'),
                          subtitle: Text('${r['proxy']}'),
                          trailing: Switch(
                            value: (r['extra'] as Json?)?['disabled'] != true,
                            onChanged: c.busy
                                ? null
                                : (v) => c.perform(() async {
                                    await c.api('PATCH', '/rules/disable', {
                                      '${r['index']}': !v,
                                    });
                                  }),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(c.tr('版本與更新', 'Versions and updates')),
            Text('Aster Desktop 0.1.0'),
            if (c.coreVersion.isNotEmpty) Text('Aster Core ${c.coreVersion}'),
            const SizedBox(height: 8),
            Text(
              c.tr(
                '核心使用官方 main 測試版，更新只會在你點擊時執行。',
                'Core updates use official main prereleases and run only when you choose.',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: c.busy ? null : () => showUpdateDialog(context, c),
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(c.tr('檢查更新', 'Check for updates')),
                ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://astercore.fubukishop.app/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: Text(c.tr('使用說明', 'User guide')),
                ),
              ],
            ),
            if (c.updateProgress.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(switch (c.updateProgress) {
                  'download' => c.tr('正在下載核心…', 'Downloading core…'),
                  'verify' => c.tr('正在驗證新核心…', 'Verifying core…'),
                  'complete' => c.tr('核心已更新。', 'Core updated.'),
                  _ => c.updateProgress,
                }),
              ),
            const SizedBox(height: 16),
            Text(
              c.tr(
                '原核心採用 GPL-3.0，授權與來源資訊隨套件提供。',
                'The original core uses GPL-3.0. License and source details are bundled.',
              ),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
