import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'application_rules.dart';
import 'controller.dart';
import 'dialogs.dart';

enum _RuleAction { up, down, toggle, copy, delete }

class _RuleView {
  const _RuleView({
    required this.rule,
    required this.type,
    required this.match,
    required this.target,
    required this.position,
    required this.disabled,
  });

  factory _RuleView.parse(
    String rule, {
    required int position,
    required bool disabled,
  }) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (parts.length < 2) {
      return _RuleView(
        rule: rule,
        type: rule,
        match: '',
        target: '',
        position: position,
        disabled: disabled,
      );
    }
    final type = parts.first;
    if (type == 'MATCH' || type == 'FINAL') {
      return _RuleView(
        rule: rule,
        type: type,
        match: '',
        target: parts[1],
        position: position,
        disabled: disabled,
      );
    }
    return _RuleView(
      rule: rule,
      type: type,
      match: parts.length > 1 ? parts[1] : '',
      target: parts.length > 2 ? parts[2] : '',
      position: position,
      disabled: disabled,
    );
  }

  final String rule, type, match, target;
  final int position;
  final bool disabled;
}

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
    final entries = <_RuleView>[
      for (var i = 0; i < enabled.length; i++)
        _RuleView.parse(enabled[i], position: i, disabled: false),
      for (final rule in disabled)
        _RuleView.parse(rule, position: -1, disabled: true),
    ];
    final query = search.text.trim().toLowerCase();
    final visible = entries
        .where(
          (entry) =>
              query.isEmpty ||
              entry.rule.toLowerCase().contains(query) ||
              entry.type.toLowerCase().contains(query) ||
              entry.target.toLowerCase().contains(query),
        )
        .toList();
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 0, compact ? 16 : 28, 20),
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
          if (compact)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('rules-search'),
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: c.tr('搜尋規則或出口', 'Search rules or routes'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('rules-add'),
                  tooltip: c.tr('新增規則', 'Add rule'),
                  onPressed: c.active == null || c.busy
                      ? null
                      : () => showRuleEditor(context, c),
                  icon: const Icon(Icons.add),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('rules-search'),
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
          const SizedBox(height: 10),
          Text(
            c.tr(
              '${enabled.length} 條啟用 · ${disabled.length} 條停用 · 顯示 ${visible.length} 條',
              '${enabled.length} enabled · ${disabled.length} disabled · ${visible.length} shown',
            ),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      entries.isEmpty
                          ? c.tr('目前沒有規則', 'No rules yet')
                          : c.tr('沒有符合的規則', 'No matching rules'),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ruleCard(
                      context,
                      visible[i],
                      enabled,
                      compact: compact,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _ruleCard(
    BuildContext context,
    _RuleView rule,
    List<String> enabled, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = rule.match.isEmpty
        ? c.tr('符合所有剩餘流量', 'All remaining traffic')
        : rule.match;
    return Card(
      key: ValueKey(
        'rule-row-${rule.position >= 0 ? rule.position : 'off-${rule.rule}'}',
      ),
      margin: EdgeInsets.zero,
      color: rule.disabled
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showRuleDetails(context, rule),
        child: Padding(
          padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: compact ? 34 : 40,
                height: compact ? 34 : 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: rule.disabled
                      ? scheme.surfaceContainerHighest
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  rule.position >= 0 ? '${rule.position + 1}' : '—',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: rule.disabled
                        ? scheme.onSurfaceVariant
                        : scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Opacity(
                  opacity: rule.disabled ? .58 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: compact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _RuleChip(label: _ruleTypeLabel(rule.type)),
                          if (rule.target.isNotEmpty)
                            _RuleChip(
                              label: '${c.tr('出口', 'Route')} · ${rule.target}',
                              emphasized: true,
                            ),
                          if (rule.disabled)
                            _RuleChip(label: c.tr('已停用', 'Disabled')),
                        ],
                      ),
                      if (rule.match.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          rule.rule,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              PopupMenuButton<_RuleAction>(
                key: ValueKey(
                  'rule-menu-${rule.position >= 0 ? rule.position : 'off-${rule.rule}'}',
                ),
                enabled: !c.busy,
                tooltip: c.tr('規則操作', 'Rule actions'),
                onSelected: (value) =>
                    _handleAction(context, rule, value, enabled),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _RuleAction.up,
                    enabled: !rule.disabled && rule.position > 0,
                    child: Text(c.tr('向上移動', 'Move up')),
                  ),
                  PopupMenuItem(
                    value: _RuleAction.down,
                    enabled:
                        !rule.disabled &&
                        rule.position >= 0 &&
                        rule.position < enabled.length - 1,
                    child: Text(c.tr('向下移動', 'Move down')),
                  ),
                  PopupMenuItem(
                    value: _RuleAction.toggle,
                    child: Text(
                      rule.disabled
                          ? c.tr('啟用規則', 'Enable rule')
                          : c.tr('停用規則', 'Disable rule'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _RuleAction.copy,
                    child: Text(c.tr('複製規則', 'Copy rule')),
                  ),
                  PopupMenuItem(
                    value: _RuleAction.delete,
                    child: Text(
                      c.tr('刪除規則', 'Delete rule'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _ruleTypeLabel(String type) => switch (type) {
    'MATCH' || 'FINAL' => c.tr('全部流量', 'All traffic'),
    'DOMAIN' => c.tr('完整網域', 'Exact domain'),
    'DOMAIN-SUFFIX' => c.tr('網域及子網域', 'Domain suffix'),
    'IP-CIDR' || 'IP-CIDR6' => c.tr('IP 範圍', 'IP range'),
    'PROCESS-NAME' => c.tr('執行檔名稱', 'Process name'),
    'PROCESS-PATH' => c.tr('應用程式路徑', 'Process path'),
    _ => type,
  };

  Future<void> _handleAction(
    BuildContext context,
    _RuleView rule,
    _RuleAction selected,
    List<String> enabled,
  ) async {
    switch (selected) {
      case _RuleAction.up:
      case _RuleAction.down:
        if (rule.position < 0) return;
        final order = [...enabled];
        final target = selected == _RuleAction.up
            ? rule.position - 1
            : rule.position + 1;
        if (target < 0 || target >= order.length) return;
        order[rule.position] = order[target];
        order[target] = rule.rule;
        await action(rule.rule, 'order', order: order);
      case _RuleAction.toggle:
        await action(rule.rule, rule.disabled ? 'enable' : 'disable');
      case _RuleAction.copy:
        await Clipboard.setData(ClipboardData(text: rule.rule));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(c.tr('規則已複製', 'Rule copied'))));
        }
      case _RuleAction.delete:
        if (!await confirm(context, c, c.tr('刪除這條規則？', 'Delete this rule?'))) {
          return;
        }
        await c.perform(() async {
          await c.backend.call('patchProfile', {
            'id': c.activeId,
            'removeRule': rule.rule,
          });
        });
        if (mounted) setState(() {});
    }
  }

  Future<void> _showRuleDetails(BuildContext context, _RuleView rule) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(c.tr('規則詳細資料', 'Rule details')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RuleChip(label: _ruleTypeLabel(rule.type)),
                if (rule.match.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    c.tr('比對內容', 'Match value'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(rule.match),
                ],
                if (rule.target.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    c.tr('出口', 'Route'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(rule.target),
                ],
                const SizedBox(height: 14),
                Text(
                  c.tr('完整規則', 'Full rule'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  rule.rule,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: rule.rule));
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(c.tr('複製', 'Copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(c.tr('關閉', 'Close')),
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

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.label, this.emphasized = false});
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: emphasized
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: emphasized
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
