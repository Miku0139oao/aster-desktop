import 'dart:convert';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'dialogs.dart';
import 'pages.dart' show PageBody, Panel;

Json plainMap(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Future<void> previewSubscription(
  BuildContext context,
  AppController c,
  Profile p,
) async {
  Json? preview;
  final ok = await c.perform(() async {
    preview = await c.backend.call('previewRefresh', {'id': p.id}) as Json;
  });
  if (!ok || !context.mounted) return;
  final apply = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(c.tr('訂閱更新預覽', 'Subscription update preview')),
      content: SizedBox(
        width: 620,
        height: 400,
        child: ListView(
          children: [
            Text(
              c.tr(
                '自訂節點、群組與分流規則會保留。請檢查移除的節點是否仍在使用。',
                'Custom nodes, groups and routing rules are retained. Check whether removed nodes are still in use.',
              ),
            ),
            const SizedBox(height: 16),
            for (final entry in {
              'added': c.tr('新增', 'Added'),
              'removed': c.tr('移除', 'Removed'),
              'changed': c.tr('變更', 'Changed'),
              'warnings': c.tr('匯入警告', 'Import warnings'),
            }.entries)
              ExpansionTile(
                initiallyExpanded: entry.key == 'removed',
                title: Text(
                  '${entry.value} · ${(preview![entry.key] as List? ?? []).length}',
                ),
                children: [
                  for (final name in preview![entry.key] as List? ?? [])
                    ListTile(dense: true, title: Text(name.toString())),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(c.tr('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(c.tr('套用更新', 'Apply update')),
        ),
      ],
    ),
  );
  if (apply == true) {
    await c.perform(() async {
      await c.backend.call('applyRefresh', {
        'id': p.id,
        'token': preview!['token'],
      });
    });
  }
}

Future<void> editProfileMetadata(
  BuildContext context,
  AppController c,
  Profile p,
) async {
  final name = TextEditingController(text: p.name);
  final url = TextEditingController(text: p.url);
  var interval = p.json['intervalHours'] as int? ?? -1;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(c.tr('訂閱設定', 'Profile settings')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: c.tr('名稱', 'Name')),
              ),
              const SizedBox(height: 16),
              if (p.url.isNotEmpty)
                TextField(
                  controller: url,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: c.tr('訂閱網址', 'Subscription URL'),
                  ),
                ),
              const SizedBox(height: 16),
              if (p.url.isNotEmpty)
                DropdownButtonFormField<int>(
                  initialValue: interval,
                  decoration: InputDecoration(
                    labelText: c.tr('自動更新', 'Automatic refresh'),
                  ),
                  items: [
                    for (final hours in {-1, 0, 1, 6, 12, 24, 168, interval})
                      DropdownMenuItem(
                        value: hours,
                        child: Text(
                          hours == -1
                              ? c.tr('跟隨全域設定', 'Use global setting')
                              : hours == 0
                              ? c.tr('僅手動更新', 'Manual only')
                              : c.tr('每 $hours 小時', 'Every $hours hours'),
                        ),
                      ),
                  ],
                  onChanged: (value) => update(() => interval = value!),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(c.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(context, true);
            },
            child: Text(c.tr('儲存', 'Save')),
          ),
        ],
      ),
    ),
  );
  if (accepted == true) {
    await c.perform(() async {
      await c.backend.call('profileMetadata', {
        'id': p.id,
        'name': name.text.trim(),
        'url': url.text.trim(),
        'intervalHours': interval == -1 ? null : interval,
      });
    });
  }
  name.dispose();
  url.dispose();
}

Future<void> showLatencySettings(BuildContext context, AppController c) async {
  final url = TextEditingController(
    text:
        c.preferences['testUrl'] as String? ??
        'https://www.gstatic.com/generate_204',
  );
  var timeout = c.preferences['testTimeout'] as int? ?? 5000;
  var concurrency = c.preferences['testConcurrency'] as int? ?? 4;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(c.tr('測速設定', 'Latency test settings')),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: url,
                decoration: InputDecoration(
                  labelText: c.tr(
                    '測試網址（HTTP／HTTPS）',
                    'Test URL (HTTP / HTTPS)',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: timeout,
                decoration: InputDecoration(labelText: c.tr('逾時', 'Timeout')),
                items: [
                  for (final v in [3000, 5000, 10000, 15000])
                    DropdownMenuItem(value: v, child: Text('${v ~/ 1000} s')),
                ],
                onChanged: (v) => update(() => timeout = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: concurrency,
                decoration: InputDecoration(
                  labelText: c.tr('同時測試數', 'Concurrency'),
                ),
                items: [
                  for (final v in [1, 2, 4, 8])
                    DropdownMenuItem(value: v, child: Text('$v')),
                ],
                onChanged: (v) => update(() => concurrency = v!),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(c.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final u = Uri.tryParse(url.text.trim());
              if (u != null &&
                  ['http', 'https'].contains(u.scheme) &&
                  u.host.isNotEmpty) {
                Navigator.pop(context, true);
              }
            },
            child: Text(c.tr('儲存', 'Save')),
          ),
        ],
      ),
    ),
  );
  if (accepted == true) {
    await c.savePreferences({
      'testUrl': url.text.trim(),
      'testTimeout': timeout,
      'testConcurrency': concurrency,
    });
  }
  url.dispose();
}

class ObjectManager extends StatefulWidget {
  const ObjectManager({super.key, required this.c});
  final AppController c;
  @override
  State<ObjectManager> createState() => _ObjectManagerState();
}

class _ObjectManagerState extends State<ObjectManager> {
  String field = 'proxies';
  final search = TextEditingController();
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    c.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> edit({String? name, Json? object, bool copy = false}) =>
      showDialog<void>(
        context: context,
        builder: (_) => ObjectEditor(
          c: c,
          field: field,
          oldName: copy ? null : name,
          initial: object == null ? null : {...object, 'name': name},
        ),
      );
  @override
  Widget build(BuildContext context) {
    final raw = c.profileDocument?[field];
    final entries = <String, Json>{};
    if (raw is List) {
      for (final item in raw) {
        entries[item['name'] as String] = Map<String, dynamic>.from(
          item as Map,
        );
      }
    }
    if (raw is Map) {
      for (final item in raw.entries) {
        entries[item.key as String] = Map<String, dynamic>.from(
          item.value as Map,
        );
      }
    }
    entries.removeWhere(
      (name, _) =>
          name.startsWith('Aster-App-') ||
          !name.toLowerCase().contains(search.text.toLowerCase()),
    );
    return SizedBox(
      width: 820,
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final type in {
                'proxies': c.tr('節點', 'Nodes'),
                'proxy-groups': c.tr('群組', 'Groups'),
                'proxy-providers': c.tr('節點提供者', 'Proxy providers'),
                'rule-providers': c.tr('規則提供者', 'Rule providers'),
              }.entries)
                ChoiceChip(
                  label: Text(type.value),
                  selected: field == type.key,
                  onSelected: (_) => setState(() {
                    field = type.key;
                    search.clear();
                  }),
                ),
            ],
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
                    hintText: c.tr('搜尋名稱', 'Search names'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: c.active == null || c.busy ? null : () => edit(),
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
                final entry = entries.entries.elementAt(i);
                return ListTile(
                  title: Text(entry.key),
                  subtitle: Text(
                    '${entry.value['type'] ?? ''} ${entry.value['server'] ?? ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: c.tr('編輯', 'Edit'),
                        onPressed: c.busy
                            ? null
                            : () => edit(name: entry.key, object: entry.value),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: c.tr('複製', 'Duplicate'),
                        onPressed: c.busy
                            ? null
                            : () => edit(
                                name: entry.key,
                                object: entry.value,
                                copy: true,
                              ),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      if (c.running && field.endsWith('providers'))
                        IconButton(
                          tooltip: c.tr('立即更新', 'Update now'),
                          onPressed: c.busy
                              ? null
                              : () => c.perform(() async {
                                  await c.api(
                                    'PUT',
                                    '/providers/${field == 'proxy-providers' ? 'proxies' : 'rules'}/${Uri.encodeComponent(entry.key)}',
                                  );
                                }),
                          icon: const Icon(Icons.refresh),
                        ),
                      IconButton(
                        tooltip: c.tr('刪除', 'Delete'),
                        onPressed: c.busy
                            ? null
                            : () async {
                                if (await confirm(
                                  context,
                                  c,
                                  c.tr(
                                    '刪除 ${entry.key}？仍被群組或規則使用時會保留原設定。',
                                    'Delete ${entry.key}? Referenced objects cannot be removed.',
                                  ),
                                )) {
                                  await c.perform(() async {
                                    await c.backend.call('manageObject', {
                                      'id': c.activeId,
                                      'field': field,
                                      'oldName': entry.key,
                                      'action': 'delete',
                                    });
                                  });
                                }
                              },
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
              '此處的自訂變更會保留至下次訂閱更新。儲存前會驗證並備份，失敗保留原設定。',
              'Custom changes survive subscription refreshes. Changes are validated and backed up; failures retain the previous configuration.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    c.removeListener(changed);
    search.dispose();
    super.dispose();
  }
}

Future<void> showObjectManager(BuildContext context, AppController c) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(c.tr('節點與群組管理', 'Node and group management')),
        content: ObjectManager(c: c),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(c.tr('完成', 'Done')),
          ),
        ],
      ),
    );

class ObjectEditor extends StatefulWidget {
  const ObjectEditor({
    super.key,
    required this.c,
    required this.field,
    this.oldName,
    this.initial,
  });
  final AppController c;
  final String field;
  final String? oldName;
  final Json? initial;
  @override
  State<ObjectEditor> createState() => _ObjectEditorState();
}

class _ObjectEditorState extends State<ObjectEditor> {
  final form = GlobalKey<FormState>();
  final inputs = <String, TextEditingController>{};
  late Json object;
  late String type;
  late final String profileId;
  final members = <String>{}, providers = <String>{};
  bool working = false;
  String? error;
  AppController get c => widget.c;
  bool get node => widget.field == 'proxies';
  bool get group => widget.field == 'proxy-groups';
  @override
  void initState() {
    super.initState();
    profileId = c.activeId;
    object = widget.initial == null ? {} : plainMap(widget.initial!);
    if (widget.oldName == null &&
        widget.initial != null &&
        object['name'] != null) {
      object['name'] = '${object['name']} (copy)';
    }
    type =
        object['type'] as String? ??
        (node
            ? 'vless'
            : group
            ? 'select'
            : 'http');
    members.addAll((object['proxies'] as List? ?? []).cast<String>());
    providers.addAll((object['use'] as List? ?? []).cast<String>());
  }

  TextEditingController input(String key, [dynamic fallback]) =>
      inputs.putIfAbsent(
        key,
        () => TextEditingController(
          text: (object[key] ?? fallback ?? '').toString(),
        ),
      );
  Widget text(
    String key,
    String label, {
    bool required = false,
    bool secret = false,
    String? initial,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: input(key, initial),
      obscureText: secret,
      readOnly: key == 'name' && widget.oldName != null,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        if (required && (value ?? '').trim().isEmpty) {
          return c.tr('請填寫此欄位', 'Required');
        }
        if (number &&
            (value ?? '').isNotEmpty &&
            (int.tryParse(value!) == null ||
                int.parse(value) < 1 ||
                (key == 'port' && int.parse(value) > 65535))) {
          return c.tr('請輸入有效的正整數', 'Enter a valid positive integer');
        }
        return null;
      },
    ),
  );
  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      working = true;
      error = null;
    });
    final result = {...object, 'type': type};
    for (final entry in inputs.entries) {
      final value = entry.value.text.trim();
      if (value.isNotEmpty) {
        result[entry.key] =
            ['port', 'interval', 'tolerance'].contains(entry.key)
            ? int.parse(value)
            : value;
      } else {
        result.remove(entry.key);
      }
    }
    final name = result['name'] as String;
    if (widget.field.endsWith('providers')) result.remove('name');
    if (group) {
      result['proxies'] = members.toList();
      result['use'] = providers.toList();
    }
    if (node) {
      final servername = result.remove('_servername');
      final pk = result.remove('_publicKey'), sid = result.remove('_shortId');
      result.remove('sni');
      result.remove('servername');
      if (servername != null) {
        result[type == 'trojan' || type == 'anytls' || type == 'hysteria2'
                ? 'sni'
                : 'servername'] =
            servername;
      }
      if (pk != null) {
        result['tls'] = true;
        result['reality-opts'] = {
          ...((object['reality-opts'] as Map?) ?? {}),
          'public-key': pk,
          'short-id': sid ?? '',
        };
      } else {
        result.remove('reality-opts');
      }
      if (result['network'] == 'ws') {
        final path = result.remove('_wsPath'), host = result.remove('_wsHost');
        result['ws-opts'] = {
          ...((object['ws-opts'] as Map?) ?? {}),
          'path': path ?? '/',
          if (host != null)
            'headers': {
              ...((object['ws-opts'] as Map?)?['headers'] as Map? ?? {}),
              'Host': host,
            },
        };
      } else {
        result.remove('_wsPath');
        result.remove('_wsHost');
      }
      if (result['network'] == 'grpc') {
        result['grpc-opts'] = {
          ...((object['grpc-opts'] as Map?) ?? {}),
          'grpc-service-name': result.remove('_grpcService') ?? '',
        };
      } else {
        result.remove('_grpcService');
      }
    }
    try {
      if (profileId != c.activeId) {
        throw BackendException(
          c.tr(
            '目前設定已變更，請重新開啟編輯器',
            'The active configuration changed. Reopen the editor.',
          ),
        );
      }
      final success = await c.perform(() async {
        await c.backend.call('manageObject', {
          'id': profileId,
          'field': widget.field,
          'oldName': name,
          'object': result,
          'action': widget.oldName == null ? 'create' : 'update',
        });
      });
      if (!success) {
        throw BackendException(
          c.error ?? c.tr('另一項操作正在進行', 'Another operation is in progress'),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> chooseMembers(List<String> available) async {
    final query = TextEditingController();
    final selected = {...members};
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final entries = available
              .where(
                (name) => name.toLowerCase().contains(query.text.toLowerCase()),
              )
              .toList();
          return AlertDialog(
            title: Text(c.tr('選擇群組成員', 'Choose group members')),
            content: SizedBox(
              width: 600,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: c.tr('搜尋節點或群組', 'Search nodes or groups'),
                    ),
                    onChanged: (_) => update(() {}),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => update(() => selected.addAll(entries)),
                        child: Text(c.tr('選取搜尋結果', 'Select search results')),
                      ),
                      TextButton(
                        onPressed: () => update(selected.clear),
                        child: Text(c.tr('清除選取', 'Clear selection')),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, i) => CheckboxListTile(
                        title: Text(
                          entries[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: selected.contains(entries[i]),
                        onChanged: (v) => update(
                          () => v == true
                              ? selected.add(entries[i])
                              : selected.remove(entries[i]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(c.tr('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  c.tr(
                    '使用 ${selected.length} 個成員',
                    'Use ${selected.length} members',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (save == true && mounted) {
      setState(
        () => members
          ..clear()
          ..addAll(selected),
      );
    }
    query.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = node
        ? [
            'vless',
            'vmess',
            'ss',
            'trojan',
            'hysteria2',
            'tuic',
            'anytls',
            'socks5',
            'http',
          ]
        : group
        ? ['select', 'url-test', 'fallback', 'load-balance']
        : ['http', 'file', 'inline'];
    if (!options.contains(type)) options.add(type);
    final nodes = <String>{
      'DIRECT',
      'REJECT',
      for (final n in c.profileDocument?['proxies'] as List? ?? [])
        n['name'] as String,
      for (final g in c.profileDocument?['proxy-groups'] as List? ?? [])
        if (g['name'] != widget.oldName &&
            !(g['name'] as String).startsWith('Aster-App-'))
          g['name'] as String,
    };
    return AlertDialog(
      title: Text(
        c.tr(
          widget.oldName == null ? '新增項目' : '編輯項目',
          widget.oldName == null ? 'Add item' : 'Edit item',
        ),
      ),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .65,
        child: Form(
          key: form,
          child: ListView(
            children: [
              text(
                'name',
                c.tr('名稱', 'Name'),
                required: true,
                initial:
                    widget.oldName ??
                    (widget.initial?['name'] == null
                        ? ''
                        : '${widget.initial!['name']} (copy)'),
              ),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: InputDecoration(labelText: c.tr('類型', 'Type')),
                items: [
                  for (final option in options)
                    DropdownMenuItem(value: option, child: Text(option)),
                ],
                onChanged: working ? null : (v) => setState(() => type = v!),
              ),
              const SizedBox(height: 12),
              if (node) ...[
                text('server', c.tr('伺服器', 'Server'), required: true),
                text(
                  'port',
                  c.tr('連接埠', 'Port'),
                  required: true,
                  number: true,
                  initial: '443',
                ),
                if (['vless', 'vmess', 'tuic'].contains(type))
                  text('uuid', 'UUID', required: true),
                if ([
                  'ss',
                  'trojan',
                  'hysteria2',
                  'tuic',
                  'anytls',
                  'socks5',
                  'http',
                ].contains(type))
                  text(
                    'password',
                    c.tr('密碼', 'Password'),
                    secret: true,
                    required: !['socks5', 'http'].contains(type),
                  ),
                if (['socks5', 'http'].contains(type))
                  text('username', c.tr('使用者名稱', 'Username')),
                if (type == 'ss')
                  text(
                    'cipher',
                    c.tr('加密方式', 'Cipher'),
                    required: true,
                    initial: 'chacha20-ietf-poly1305',
                  ),
                SwitchListTile(
                  title: const Text('TLS'),
                  value:
                      object['tls'] == true ||
                      ['trojan', 'anytls', 'hysteria2', 'tuic'].contains(type),
                  onChanged:
                      ['trojan', 'anytls', 'hysteria2', 'tuic'].contains(type)
                      ? null
                      : (v) => setState(() => object['tls'] = v),
                ),
                text(
                  '_servername',
                  c.tr('TLS 伺服器名稱（SNI）', 'TLS server name (SNI)'),
                  initial: (object['servername'] ?? object['sni']) as String?,
                ),
                if (['vless', 'vmess', 'trojan'].contains(type)) ...[
                  DropdownButtonFormField<String>(
                    initialValue: object['network'] as String? ?? 'tcp',
                    decoration: InputDecoration(
                      labelText: c.tr('傳輸方式', 'Transport'),
                    ),
                    items: [
                      for (final network in {
                        'tcp',
                        'ws',
                        'grpc',
                        object['network'] as String? ?? 'tcp',
                      })
                        DropdownMenuItem(value: network, child: Text(network)),
                    ],
                    onChanged: (v) => setState(() => object['network'] = v),
                  ),
                  const SizedBox(height: 12),
                  if (object['network'] == 'ws') ...[
                    text(
                      '_wsPath',
                      c.tr('WebSocket 路徑', 'WebSocket path'),
                      initial:
                          (object['ws-opts'] as Map?)?['path'] as String? ??
                          '/',
                    ),
                    text(
                      '_wsHost',
                      'WebSocket Host',
                      initial:
                          ((object['ws-opts'] as Map?)?['headers']
                                  as Map?)?['Host']
                              as String?,
                    ),
                  ],
                  if (object['network'] == 'grpc')
                    text(
                      '_grpcService',
                      'gRPC Service',
                      initial:
                          (object['grpc-opts'] as Map?)?['grpc-service-name']
                              as String?,
                    ),
                ],
                if (['vless', 'anytls'].contains(type)) ...[
                  text(
                    '_publicKey',
                    'REALITY Public Key',
                    initial:
                        (object['reality-opts'] as Map?)?['public-key']
                            as String?,
                  ),
                  text(
                    '_shortId',
                    'REALITY Short ID',
                    initial:
                        (object['reality-opts'] as Map?)?['short-id']
                            as String?,
                  ),
                ],
                if (type == 'vless') text('flow', 'Flow'),
                if (['vless', 'vmess', 'trojan', 'anytls'].contains(type))
                  text('client-fingerprint', c.tr('TLS 指紋', 'TLS fingerprint')),
                SwitchListTile(
                  title: const Text('UDP'),
                  value: object['udp'] != false,
                  onChanged: (v) => setState(() => object['udp'] = v),
                ),
              ],
              if (group) ...[
                if (type != 'select') ...[
                  text(
                    'url',
                    c.tr('測試網址', 'Test URL'),
                    initial: 'https://www.gstatic.com/generate_204',
                  ),
                  text(
                    'interval',
                    c.tr('測試間隔（秒）', 'Test interval (seconds)'),
                    initial: '300',
                    number: true,
                  ),
                ],
                SwitchListTile(
                  title: Text(c.tr('包含全部本機節點', 'Include all local nodes')),
                  value: object['include-all-proxies'] == true,
                  onChanged: (v) =>
                      setState(() => object['include-all-proxies'] = v),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      chooseMembers({...nodes, ...members}.toList()),
                  icon: const Icon(Icons.checklist),
                  label: Text(
                    c.tr(
                      '選擇成員（${members.length}）',
                      'Choose members (${members.length})',
                    ),
                  ),
                ),
                Text(
                  members.take(10).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Text(c.tr('引用節點提供者', 'Use proxy providers')),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final name
                        in (c.profileDocument?['proxy-providers'] as Map? ?? {})
                            .keys
                            .cast<String>())
                      FilterChip(
                        label: Text(name),
                        selected: providers.contains(name),
                        onSelected: (v) => setState(
                          () =>
                              v ? providers.add(name) : providers.remove(name),
                        ),
                      ),
                  ],
                ),
              ],
              if (!node && !group) ...[
                if (type == 'http')
                  text('url', c.tr('訂閱網址', 'Subscription URL'), required: true),
                if (type == 'file')
                  text('path', c.tr('檔案路徑', 'File path'), required: true),
                text(
                  'interval',
                  c.tr('更新間隔（秒）', 'Refresh interval (seconds)'),
                  initial: '86400',
                  number: true,
                ),
                if (widget.field == 'rule-providers') ...[
                  text(
                    'behavior',
                    c.tr(
                      '規則格式：classical / domain / ipcidr',
                      'Behavior: classical / domain / ipcidr',
                    ),
                    required: true,
                    initial: 'classical',
                  ),
                  text(
                    'format',
                    c.tr('檔案格式：yaml / text / mrs', 'Format: yaml / text / mrs'),
                    initial: 'yaml',
                  ),
                ],
                if (type == 'inline' && object['payload'] == null)
                  Text(
                    c.tr(
                      '內嵌內容請先匯入設定，再於此處管理。',
                      'Import inline content first, then manage it here.',
                    ),
                  ),
              ],
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
          onPressed: working ? null : save,
          child: Text(
            c.tr(
              working ? '驗證中…' : '驗證並儲存',
              working ? 'Validating…' : 'Validate and save',
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final input in inputs.values) {
      input.dispose();
    }
    super.dispose();
  }
}

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, required this.c});
  final AppController c;
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<Json> checks = [];
  bool working = false;
  String? error;
  AppController get c => widget.c;
  final dnsName = TextEditingController(text: 'example.com');
  String dnsType = 'A';
  Json? dnsResult;
  @override
  void dispose() {
    dnsName.dispose();
    super.dispose();
  }

  Future<void> run() async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final result = await c.backend.call('diagnose') as List;
      if (mounted) setState(() => checks = result.cast<Json>());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.tr('找出卡在哪一步', 'Find where the connection fails'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              c.tr(
                '檢查不會變更網路設定。會向 gstatic 發送 DNS／HTTPS 測試；系統路由請求與本機代理請求分開顯示。',
                'Tests do not change network settings. DNS / HTTPS tests contact gstatic; system routing and local proxy requests are tested separately.',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: working ? null : run,
              icon: const Icon(Icons.troubleshoot),
              label: Text(
                c.tr(
                  working ? '檢查中…' : '開始診斷',
                  working ? 'Checking…' : 'Run diagnostics',
                ),
              ),
            ),
            if (working)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      if (error != null) SelectableText(error!),
      for (final check in checks)
        Panel(
          padding: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  check['status'] == 'pass'
                      ? Icons.check_circle_outline
                      : check['status'] == 'skip'
                      ? Icons.remove_circle_outline
                      : Icons.error_outline,
                  color: check['status'] == 'fail'
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  {
                        'core': c.tr('核心', 'Core'),
                        'service': c.tr('背景服務', 'Background service'),
                        'network': c.tr('出口網路', 'Outbound network'),
                        'dns': c.tr('系統 DNS', 'System DNS'),
                        'systemRequest': c.tr(
                          '系統路由 HTTPS（TUN 開啟時經 TUN）',
                          'System-route HTTPS (via TUN when enabled)',
                        ),
                        'proxyRequest': c.tr('本機代理 HTTPS', 'Local proxy HTTPS'),
                      }[check['kind']] ??
                      check['kind'] as String,
                ),
                trailing: Text('${check['milliseconds']} ms'),
              ),
              if (check['status'] == 'fail')
                Text(switch (check['kind']) {
                  'core' => c.tr(
                    '回首頁重新連線；若失敗，查看日誌。',
                    'Reconnect on Home; check Logs if it fails.',
                  ),
                  'service' => c.tr(
                    '到設定安裝並授權背景服務。',
                    'Install and approve the background service in Settings.',
                  ),
                  'network' => c.tr(
                    '回首頁選擇正在使用的 Wi-Fi 或有線網路。',
                    'Choose the active Wi-Fi or wired interface on Home.',
                  ),
                  'dns' => c.tr(
                    '檢查 DNS 設定及目前網路。',
                    'Check DNS settings and your network.',
                  ),
                  _ => c.tr(
                    '若本機代理成功、系統路由失敗，請檢查 TUN 出口網路及其他 VPN。若兩者失敗，請更換節點後再試。',
                    'If the local proxy passes but system routing fails, check the TUN interface and other VPNs. If both fail, select another node and retry.',
                  ),
                }),
              ExpansionTile(
                title: Text(c.tr('技術詳情', 'Technical details')),
                children: [SelectableText(check['detail'] as String)],
              ),
            ],
          ),
        ),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              c.tr('核心 DNS 查詢', 'Core DNS query'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: dnsName,
              decoration: InputDecoration(
                labelText: c.tr('網域名稱', 'Domain name'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: dnsType,
              items: [
                for (final type in [
                  'A',
                  'AAAA',
                  'CNAME',
                  'MX',
                  'TXT',
                  'NS',
                  'HTTPS',
                ])
                  DropdownMenuItem(value: type, child: Text(type)),
              ],
              onChanged: (v) => setState(() => dnsType = v!),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: !c.running || working
                      ? null
                      : () async {
                          setState(() => working = true);
                          try {
                            final result = await c.api(
                              'GET',
                              '/dns/query?name=${Uri.encodeComponent(dnsName.text.trim())}&type=$dnsType',
                            ) as Json;
                            if (mounted) setState(() => dnsResult = result);
                          } catch (e) {
                            if (mounted) setState(() => error = e.toString());
                          } finally {
                            if (mounted) setState(() => working = false);
                          }
                        },
                  child: Text(c.tr('查詢', 'Query')),
                ),
                OutlinedButton(
                  onPressed: !c.running || working
                      ? null
                      : () async {
                          try {
                            await c.api('POST', '/cache/dns/flush');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    c.tr('DNS 快取已清除', 'DNS cache cleared'),
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) setState(() => error = e.toString());
                          }
                        },
                  child: Text(c.tr('清除 DNS 快取', 'Flush DNS cache')),
                ),
              ],
            ),
            if (dnsResult != null)
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(dnsResult),
              ),
          ],
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: () => c.navigate(0),
            child: Text(c.tr('首頁／出口網路', 'Home / network')),
          ),
          OutlinedButton(
            onPressed: () => c.navigate(5),
            child: Text(c.tr('服務與網路設定', 'Service and network settings')),
          ),
          OutlinedButton(
            onPressed: () => c.navigate(4),
            child: Text(c.tr('查看日誌', 'View logs')),
          ),
          if (checks.isNotEmpty)
            OutlinedButton(
              onPressed: () => exportText(
                context,
                c,
                const JsonEncoder.withIndent('  ').convert(checks),
                'aster-diagnostics.json',
              ),
              child: Text(c.tr('匯出診斷', 'Export diagnostics')),
            ),
        ],
      ),
    ],
  );
}

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key, required this.c});
  final AppController c;
  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  int range = 7;
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    range = c.preferences['statisticsRange'] as int? ?? 7;
  }

  Future<void> selectRange(int value) async {
    setState(() => range = value);
    await c.savePreferences({'statisticsRange': value});
    try {
      final result =
          await c.backend.call('trafficHistory', {'days': value}) as Json;
      if (mounted && range == value) {
        c.trafficHistory = result;
        setState(() {});
      }
    } catch (e) {
      c.reportError(e.toString());
    }
  }

  Widget breakdown(List<Json> days, String field, String title) {
    final totals = <String, (num, num)>{};
    for (final day in days) {
      for (final entry in (day[field] as Map? ?? {}).entries) {
        final old = totals[entry.key] ?? (0, 0);
        totals[entry.key as String] = (
          old.$1 + (entry.value['upload'] as num? ?? 0),
          old.$2 + (entry.value['download'] as num? ?? 0),
        );
      }
    }
    final sorted = totals.entries.toList()
      ..sort(
        (a, b) => (b.value.$1 + b.value.$2).compareTo(a.value.$1 + a.value.$2),
      );
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (final entry in sorted.take(20))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                entry.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                '↓ ${bytes(entry.value.$2)} ↑ ${bytes(entry.value.$1)}',
              ),
            ),
          if (sorted.isEmpty)
            Text(c.tr('尚無活動連線樣本', 'No active-connection samples yet')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cutoff = DateTime.now().subtract(Duration(days: range - 1));
    final first = DateTime(cutoff.year, cutoff.month, cutoff.day);
    final days = (c.trafficHistory['days'] as List? ?? [])
        .cast<Json>()
        .where(
          (d) =>
              (DateTime.tryParse(d['date'] as String) ?? DateTime(1970))
                  .compareTo(first) >=
              0,
        )
        .toList();
    final up = days.fold<num>(0, (sum, d) => sum + (d['upload'] as num));
    final down = days.fold<num>(0, (sum, d) => sum + (d['download'] as num));
    final max = days.fold<num>(
      1,
      (max, d) => (d['upload'] as num) + (d['download'] as num) > max
          ? (d['upload'] as num) + (d['download'] as num)
          : max,
    );
    return PageBody(
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final v in [1, 7, 30, 365])
              ChoiceChip(
                label: Text(
                  c.tr(
                    v == 1 ? '今天' : '最近 $v 天',
                    v == 1 ? 'Today' : 'Last $v days',
                  ),
                ),
                selected: range == v,
                onSelected: (_) => selectRange(v),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          child: Wrap(
            spacing: 36,
            runSpacing: 16,
            children: [
              for (final stat in {
                c.tr('下載', 'Downloaded'): bytes(down),
                c.tr('上傳', 'Uploaded'): bytes(up),
                c.tr('總計', 'Total'): bytes(up + down),
              }.entries)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(stat.key),
                    Text(
                      stat.value,
                      style: Theme.of(context).textTheme.headlineMedium,
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
              Text(
                c.tr('每日用量', 'Daily usage'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              if (days.isEmpty)
                Text(
                  c.tr(
                    '連線後開始累積用量，重啟核心仍會保留。',
                    'Usage accumulates after connecting and survives core restarts.',
                  ),
                ),
              for (final day in days.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(day['date'] as String)),
                          Text(
                            '↓ ${bytes(day['download'] as num)}  ↑ ${bytes(day['upload'] as num)}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value:
                            ((day['upload'] as num) +
                                (day['download'] as num)) /
                            max,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Text(
          c.tr(
            '紀錄保存在本機，保存 365 天。背景程序運作時每 5 秒讀取核心總計；正常斷線會補記最後一次資料。異常退出可能遺失最後約 20 秒，休眠期間無法按日精確拆分。',
            'History stays on this device for 365 days. The desktop engine samples core totals every 5 seconds and records a final sample on normal disconnect. Abrupt exits may lose up to about 20 seconds; sleep gaps cannot be split precisely by day.',
          ),
        ),
        const SizedBox(height: 16),
        breakdown(
          days,
          'applications',
          c.tr('應用程式用量（抽樣）', 'Application usage (sampled)'),
        ),
        breakdown(days, 'routes', c.tr('出口用量（抽樣）', 'Route usage (sampled)')),
        Text(
          c.tr(
            '分類用量依活動連線抽樣，短連線或兩次抽樣間結束的連線可能漏記，因此不會等於核心總計。未保存瀏覽網域或封包內容。',
            'Breakdowns sample active connections and may miss short-lived connections, so they can differ from core totals. Browsing domains and packet contents are not stored.',
          ),
        ),
        if ((c.trafficHistory['error'] as String? ?? '').isNotEmpty)
          SelectableText(c.trafficHistory['error'] as String),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => exportText(
                context,
                c,
                'date,upload_bytes,download_bytes\n${days.map((d) => '${d['date']},${d['upload']},${d['download']}').join('\n')}',
                'aster-traffic.csv',
              ),
              icon: const Icon(Icons.download_outlined),
              label: Text(c.tr('匯出 CSV', 'Export CSV')),
            ),
            TextButton(
              onPressed: () async {
                if (await confirm(
                  context,
                  c,
                  c.tr('清除所有歷史用量？', 'Clear all usage history?'),
                )) {
                  await c.perform(() async {
                    await c.backend.call('clearTrafficHistory');
                    c.trafficHistory = await c.backend.call('trafficHistory', {
                      'days': range,
                    }) as Json;
                  });
                  if (mounted) setState(() {});
                }
              },
              child: Text(c.tr('清除紀錄', 'Clear history')),
            ),
          ],
        ),
      ],
    );
  }
}
