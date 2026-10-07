import 'package:flutter/material.dart';

import 'application_rules.dart';
import 'controller.dart';
import 'dialogs.dart';

Future<void> showRuleEditor(
  BuildContext context,
  AppController c, {
  String? path,
  String? application,
  String? host,
  String? ip,
}) => showDialog<void>(
  context: context,
  builder: (_) => RuleEditor(
    c: c,
    path: path,
    application: application,
    host: host,
    ip: ip,
  ),
);

class RuleEditor extends StatefulWidget {
  const RuleEditor({
    super.key,
    required this.c,
    this.path,
    this.application,
    this.host,
    this.ip,
  });
  final AppController c;
  final String? path, application, host, ip;
  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  final match = TextEditingController();
  String kind = 'DOMAIN';
  Map<String, dynamic>? route;
  bool working = false;
  String? error;
  late final String profileId;
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    profileId = c.activeId;
    kind = (widget.path ?? '').isNotEmpty
        ? 'PROCESS-PATH'
        : (widget.host ?? '').isNotEmpty
        ? 'DOMAIN'
        : (widget.ip ?? '').contains(':')
        ? 'IP-CIDR6'
        : 'IP-CIDR';
    setMatch();
  }

  void setMatch() {
    match.text = switch (kind) {
      'PROCESS-PATH' => widget.path ?? '',
      'PROCESS-NAME' => widget.application ?? '',
      'DOMAIN' || 'DOMAIN-SUFFIX' => widget.host ?? '',
      'IP-CIDR' => widget.ip == null ? '' : '${widget.ip}/32',
      'IP-CIDR6' => widget.ip == null ? '' : '${widget.ip}/128',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(c.tr('建立分流規則', 'Create routing rule')),
    content: SizedBox(
      width: 550,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: InputDecoration(
                labelText: c.tr('比對條件', 'Match type'),
              ),
              items: [
                for (final entry in {
                  'PROCESS-PATH': c.tr('應用程式路徑', 'Application path'),
                  'PROCESS-NAME': c.tr('執行檔名稱', 'Executable name'),
                  'DOMAIN': c.tr('完整網域', 'Exact domain'),
                  'DOMAIN-SUFFIX': c.tr('網域及子網域', 'Domain and subdomains'),
                  'IP-CIDR': c.tr('IPv4 範圍', 'IPv4 range'),
                  'IP-CIDR6': c.tr('IPv6 範圍', 'IPv6 range'),
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) => setState(() {
                kind = v!;
                setMatch();
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: match,
              decoration: InputDecoration(
                labelText: c.tr('比對內容', 'Match value'),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: working
                  ? null
                  : () async {
                      final selected = await pickApplicationRoute(
                        context,
                        c,
                        widget.application ?? match.text,
                      );
                      if (mounted && selected != null) {
                        setState(() => route = selected);
                      }
                    },
              icon: const Icon(Icons.alt_route),
              label: Text(
                route?['name'] as String? ?? c.tr('選擇出口', 'Choose route'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              c.tr(
                '這條規則會放在最前面，優先於現有規則，並適用於新連線。應用程式分流請使用 TUN 與規則模式。',
                'This rule is placed first, ahead of existing rules, and applies to new connections. Use TUN and Rule mode for application routing.',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText('$kind,${match.text},${route?['name'] ?? '…'}'),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: working ? null : () => Navigator.pop(context),
        child: Text(c.tr('取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: working || route == null || match.text.trim().isEmpty
            ? null
            : () async {
                if (match.text.contains(RegExp(r'[,\r\n]'))) {
                  setState(
                    () => error = c.tr(
                      '比對內容不可含逗號或換行',
                      'Match value cannot contain commas or newlines',
                    ),
                  );
                  return;
                }
                setState(() => working = true);
                final success = await c.perform(() async {
                  if (c.activeId != profileId) {
                    throw StateError(
                      c.tr(
                        '設定已切換，請重新開啟規則編輯器',
                        'Profile changed; reopen the rule editor',
                      ),
                    );
                  }
                  await c.backend.call('patchProfile', {
                    'id': profileId,
                    if (route!['provider'] == null)
                      'rule': '$kind,${match.text.trim()},${route!['target']}',
                    if (route!['provider'] != null)
                      'providerRoute': {
                        'kind': kind,
                        'match': match.text.trim(),
                        'provider': route!['provider'],
                        'node': route!['name'],
                      },
                  });
                });
                if (context.mounted) {
                  if (success) {
                    Navigator.pop(context);
                  } else {
                    setState(() {
                      working = false;
                      error = c.error;
                    });
                  }
                }
              },
        child: Text(
          c.tr(
            working ? '驗證中…' : '驗證並套用',
            working ? 'Validating…' : 'Validate and apply',
          ),
        ),
      ),
    ],
  );
  @override
  void dispose() {
    match.dispose();
    super.dispose();
  }
}

class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.c});
  final AppController c;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  final search = TextEditingController();
  AppController get c => widget.c;
  Future<void> action(String rule, String action, {List<String>? order}) => c
      .perform(() async {
        await c.backend.call('manageRules', {
          'id': c.activeId,
          'rule': rule,
          'action': action,
          'order': ?order,
        });
      })
      .then((_) {
        if (mounted) setState(() {});
      });
  @override
  Widget build(BuildContext context) {
    final enabled = (c.profileDocument?['rules'] as List? ?? []).cast<String>();
    final disabled = (c.active?.json['disabledRules'] as List? ?? [])
        .cast<String>();
    final all = [...enabled, ...disabled];
    final entries = all
        .where((r) => r.toLowerCase().contains(search.text.toLowerCase()))
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            c.tr(
              '由上往下比對，第一條符合的規則決定出口。停用與排序會保留至訂閱更新。',
              'Rules match from top to bottom; the first match determines the route. Disabled rules and custom order survive subscription refreshes.',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: c.tr('搜尋規則或出口', 'Search rules or routes'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: c.active == null || c.busy
                    ? null
                    : () => showRuleEditor(context, c),
                icon: const Icon(Icons.add),
                label: Text(c.tr('新增', 'Add')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final rule = entries[i];
                final index = enabled.indexOf(rule);
                final off = disabled.contains(rule);
                return ListTile(
                  leading: Text(off ? '—' : '${index + 1}'),
                  title: Tooltip(
                    message: rule,
                    child: Text(
                      rule,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: c.tr('向上移動', 'Move up'),
                        onPressed: c.busy || index <= 0
                            ? null
                            : () {
                                final order = [...enabled];
                                order[index] = order[index - 1];
                                order[index - 1] = rule;
                                action(rule, 'order', order: order);
                              },
                        icon: const Icon(Icons.arrow_upward, size: 18),
                      ),
                      IconButton(
                        tooltip: c.tr('向下移動', 'Move down'),
                        onPressed:
                            c.busy || index < 0 || index == enabled.length - 1
                            ? null
                            : () {
                                final order = [...enabled];
                                order[index] = order[index + 1];
                                order[index + 1] = rule;
                                action(rule, 'order', order: order);
                              },
                        icon: const Icon(Icons.arrow_downward, size: 18),
                      ),
                      Switch(
                        value: !off,
                        onChanged: c.busy
                            ? null
                            : (_) => action(rule, off ? 'enable' : 'disable'),
                      ),
                      IconButton(
                        tooltip: c.tr('刪除規則', 'Delete rule'),
                        onPressed: c.busy || off
                            ? null
                            : () async {
                                if (await confirm(
                                  context,
                                  c,
                                  c.tr('刪除這條規則？', 'Delete this rule?'),
                                )) {
                                  await c.perform(() async {
                                    await c.backend.call('patchProfile', {
                                      'id': c.activeId,
                                      'removeRule': rule,
                                    });
                                  });
                                  if (mounted) setState(() {});
                                }
                              },
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }
}
