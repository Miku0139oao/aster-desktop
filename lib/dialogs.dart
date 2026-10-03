import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';
import 'package:re_editor/re_editor.dart';

import 'backend.dart';
import 'controller.dart';

Future<bool> confirm(
  BuildContext context,
  AppController c,
  String text,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(c.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(c.tr('確認', 'Confirm')),
          ),
        ],
      ),
    ) ??
    false;
Future<void> showImportDialog(BuildContext context, AppController c) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _ImportDialog(c: c),
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.c});
  final AppController c;
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final name = TextEditingController(), source = TextEditingController();
  int type = 0;
  String file = '';
  bool working = false;
  String? error;
  AppController get c => widget.c;
  Future<void> submit() async {
    if (working) return;
    if (type != 2 && source.text.trim().isEmpty || type == 2 && file.isEmpty) {
      setState(
        () => error = c.tr(
          '請填入訂閱網址或選擇設定內容。',
          'Enter a subscription URL or choose a configuration.',
        ),
      );
      return;
    }
    setState(() {
      working = true;
      error = null;
    });
    try {
      await c.backend.call('import', {
        'name': name.text.trim(),
        if (type == 0) 'url': source.text.trim(),
        if (type == 1) 'content': source.text.trim(),
        if (type == 2) 'file': file,
      });
      await c.refresh();
      if (mounted) {
        Navigator.pop(context);
        c.navigate(0);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(c.tr('匯入訂閱或設定', 'Import a subscription or configuration')),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.tr(
                '選一種方式即可。匯入後會先檢查設定，再開始使用。',
                'Choose one method. Your configuration is checked before use.',
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in [
                  (0, c.tr('訂閱網址', 'Subscription URL')),
                  (1, c.tr('貼上內容', 'Paste content')),
                  (2, c.tr('設定檔', 'Local file')),
                ])
                  ChoiceChip(
                    label: Text(t.$2),
                    selected: type == t.$1,
                    onSelected: working
                        ? null
                        : (_) => setState(() {
                            type = t.$1;
                            source.clear();
                            error = null;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: name,
              enabled: !working,
              decoration: InputDecoration(
                labelText: c.tr('名稱（選填）', 'Name (optional)'),
              ),
            ),
            const SizedBox(height: 16),
            if (type < 2)
              TextField(
                key: const Key('import-source'),
                controller: source,
                enabled: !working,
                minLines: type == 0 ? 1 : 7,
                maxLines: type == 0 ? 2 : 10,
                decoration: InputDecoration(
                  labelText: type == 0
                      ? c.tr('訂閱網址', 'Subscription URL')
                      : c.tr('YAML 或節點分享連結', 'YAML or node links'),
                  hintText: type == 0 ? 'https://…' : null,
                ),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: working
                    ? null
                    : () async {
                        final selected = await openFile(
                          acceptedTypeGroups: [
                            const XTypeGroup(
                              label: 'Configuration',
                              extensions: ['yaml', 'yml', 'txt'],
                            ),
                          ],
                        );
                        if (selected != null && mounted) {
                          setState(() => file = selected.path);
                        }
                      },
                icon: const Icon(Icons.folder_open),
                label: Text(c.tr('選擇設定檔', 'Choose a file')),
              ),
              if (file.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(file.split(Platform.pathSeparator).last),
                ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
    ),
    actions: [
      TextButton(
        onPressed: working ? null : () => Navigator.pop(context),
        child: Text(c.tr('取消', 'Cancel')),
      ),
      FilledButton(
        key: const Key('import-submit'),
        onPressed: working ? null : submit,
        child: Text(c.tr('匯入並檢查', 'Import and check')),
      ),
    ],
  );
  @override
  void dispose() {
    name.dispose();
    source.dispose();
    super.dispose();
  }
}

Future<void> showYamlEditor(
  BuildContext context,
  AppController c,
  Profile profile,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _YamlDialog(c: c, profile: profile),
  );
}

class _YamlDialog extends StatefulWidget {
  const _YamlDialog({required this.c, required this.profile});
  final AppController c;
  final Profile profile;
  @override
  State<_YamlDialog> createState() => _YamlDialogState();
}

class _YamlDialogState extends State<_YamlDialog> {
  late final editor = CodeLineEditingController.fromText(
    widget.profile.content,
  );
  String? message;
  bool working = false;
  AppController get c => widget.c;
  Future<void> act(String method) async {
    setState(() {
      working = true;
      message = null;
    });
    try {
      final result = await c.backend.call(method, {
        'id': widget.profile.id,
        'content': editor.text,
      });
      if (!mounted) return;
      if (method == 'validate') {
        setState(() => message = c.tr('設定檢查通過。', 'Configuration is valid.'));
      } else {
        await c.refresh();
        if (method == 'restore') {
          editor.text = (result as Json)['content'] as String;
          setState(
            () =>
                message = c.tr('已還原上一份設定。', 'Previous configuration restored.'),
          );
        } else if (mounted) {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '${c.tr('編輯設定', 'Edit configuration')} · ${widget.profile.name}',
    ),
    content: SizedBox(
      width: 760,
      height: MediaQuery.sizeOf(context).height * .58,
      child: Column(
        children: [
          Text(
            c.tr(
              '儲存前會自動驗證並備份。桌面連線方式請在首頁調整。',
              'Saving validates and backs up this configuration. Change desktop connection settings on Overview.',
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: CodeEditor(
              key: const Key('yaml-editor'),
              controller: editor,
              readOnly: working,
              wordWrap: false,
              autocompleteSymbols: false,
              padding: const EdgeInsets.all(12),
              borderRadius: BorderRadius.circular(14),
              style: CodeEditorStyle(
                fontFamily: Platform.isWindows ? 'Consolas' : 'monospace',
                fontSize: 13,
                fontHeight: 1.5,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
              ),
              indicatorBuilder: (context, controller, chunks, notifier) =>
                  DefaultCodeLineNumber(
                    controller: controller,
                    notifier: notifier,
                  ),
            ),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(message!),
            ),
          if (working) const LinearProgressIndicator(),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: working ? null : () => act('restore'),
        child: Text(c.tr('還原上一份', 'Restore previous')),
      ),
      TextButton(
        onPressed: working ? null : () => Navigator.pop(context),
        child: Text(c.tr('取消', 'Cancel')),
      ),
      OutlinedButton(
        onPressed: working ? null : () => act('validate'),
        child: Text(c.tr('檢查設定', 'Validate')),
      ),
      FilledButton(
        onPressed: working ? null : () => act('edit'),
        child: Text(c.tr('儲存並套用', 'Save and apply')),
      ),
    ],
  );
  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }
}

Future<void> exportText(
  BuildContext context,
  AppController c,
  String content,
  String name,
) async {
  final location = await getSaveLocation(
    suggestedName: name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_'),
  );
  if (location == null) return;
  try {
    await File(location.path).writeAsString(content);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(c.tr('檔案已匯出。', 'File exported.'))));
    }
  } catch (e) {
    c.error = e.toString();
    c.reportError(c.error);
  }
}

Future<void> showPortDialog(BuildContext context, AppController c) async {
  final edit = TextEditingController(text: '${c.settings.mixedPort}');
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(c.tr('本機代理連接埠', 'Local proxy port')),
        content: TextField(
          controller: edit,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: c.tr('1024 到 65535', '1024 to 65535'),
            errorText: error,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(c.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () async {
              final value = int.tryParse(edit.text);
              if (value == null || value < 1024 || value > 65535) {
                setState(
                  () => error = c.tr('請輸入有效的連接埠。', 'Enter a valid port.'),
                );
                return;
              }
              if (await c.saveSettings({'mixedPort': value}) &&
                  context.mounted) {
                Navigator.pop(context);
              }
            },
            child: Text(c.tr('儲存', 'Save')),
          ),
        ],
      ),
    ),
  );
  edit.dispose();
}

Future<void> showDNSDialog(BuildContext context, AppController c) async {
  final p = c.active!;
  YamlMap? dns;
  try {
    dns = (loadYaml(p.content) as YamlMap)['dns'] as YamlMap?;
  } catch (_) {}
  final edit = TextEditingController(
    text: ((dns?['nameserver'] as List?) ?? ['system']).join('\n'),
  );
  bool fakeIP = dns?['enhanced-mode'] != 'redir-host';
  String? error;
  bool working = false;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(c.tr('DNS 設定', 'DNS settings')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: edit,
                minLines: 4,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: c.tr('DNS 伺服器，每行一個', 'DNS servers, one per line'),
                  helperText: c.tr(
                    '可用 system、IP 或 DoH／DoT 網址。',
                    'Use system, an IP, or a DoH / DoT URL.',
                  ),
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(c.tr('Fake-IP 模式', 'Fake-IP mode')),
                value: fakeIP,
                onChanged: working ? null : (v) => setState(() => fakeIP = v),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: working ? null : () => Navigator.pop(context),
            child: Text(c.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: working
                ? null
                : () async {
                    setState(() => working = true);
                    try {
                      final servers = edit.text
                          .split('\n')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList();
                      if (servers.isEmpty) {
                        throw BackendException(
                          c.tr(
                            '至少需要一個 DNS 伺服器。',
                            'Enter at least one DNS server.',
                          ),
                        );
                      }
                      await c.backend.call('patchProfile', {
                        'id': p.id,
                        'changes': {
                          'dns': {
                            'enable': true,
                            'nameserver': servers,
                            'enhanced-mode': fakeIP ? 'fake-ip' : 'redir-host',
                          },
                        },
                      });
                      await c.refresh();
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      setState(() => error = e.toString());
                    } finally {
                      if (context.mounted) setState(() => working = false);
                    }
                  },
            child: Text(c.tr('儲存並套用', 'Save and apply')),
          ),
        ],
      ),
    ),
  );
  edit.dispose();
}

Future<String?> selectApplicationExecutable() async {
  final file = await openFile(
    acceptedTypeGroups: Platform.isWindows
        ? [
            const XTypeGroup(label: 'Application', extensions: ['exe']),
          ]
        : Platform.isMacOS
        ? [
            const XTypeGroup(
              label: 'Application',
              uniformTypeIdentifiers: [
                'com.apple.application-bundle',
                'public.unix-executable',
              ],
            ),
          ]
        : [],
  );
  if (file == null) return null;
  if (Platform.isMacOS && file.path.endsWith('.app')) {
    final result = await Process.run('/usr/bin/plutil', [
      '-extract',
      'CFBundleExecutable',
      'raw',
      '-o',
      '-',
      '${file.path}/Contents/Info.plist',
    ]);
    final executable = (result.stdout as String).trim();
    if (result.exitCode != 0 ||
        executable.isEmpty ||
        executable == '.' ||
        executable == '..' ||
        executable.contains('/') ||
        executable.contains('\\')) {
      throw const FormatException('Cannot locate this application executable.');
    }
    final path = '${file.path}/Contents/MacOS/$executable';
    if (!await File(path).exists()) {
      throw const FormatException('Application executable does not exist.');
    }
    return path;
  }
  return file.path;
}

Future<void> showRuleDialog(
  BuildContext context,
  AppController c, {
  bool application = false,
}) async {
  final p = c.active!;
  String type = application ? 'PROCESS-NAME' : 'DOMAIN-SUFFIX';
  String target = 'DIRECT';
  final targets = <String>{'DIRECT', 'REJECT'};
  try {
    final doc = loadYaml(p.content) as YamlMap;
    for (final g in doc['proxy-groups'] as List? ?? []) {
      targets.add(g['name'] as String);
      if (application && target == 'DIRECT') target = g['name'] as String;
    }
    for (final node in doc['proxies'] as List? ?? []) {
      targets.add(node['name'] as String);
    }
    if (application) {
      final preferred = c.profileTarget;
      if (targets.contains(preferred) &&
          preferred != 'DIRECT' &&
          preferred != 'REJECT') {
        target = preferred;
      } else {
        final selector = (doc['proxy-groups'] as List? ?? [])
            .where((g) => g['type'] == 'select')
            .firstOrNull;
        if (selector != null) target = selector['name'] as String;
      }
    }
  } catch (_) {}
  String? error;
  bool working = false;
  await showDialog<void>(
    context: context,
    builder: (context) => _RuleDialogHost(
      builder: (context, payload) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            application
                ? c.tr('應用程式分流', 'Application routing')
                : c.tr('新增分流規則', 'Add routing rule'),
          ),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: type,
                  items: [
                    DropdownMenuItem(
                      value: 'DOMAIN-SUFFIX',
                      child: Text(c.tr('網域及其子網域', 'Domain and subdomains')),
                    ),
                    DropdownMenuItem(
                      value: 'DOMAIN',
                      child: Text(c.tr('完整網域', 'Exact domain')),
                    ),
                    DropdownMenuItem(
                      value: 'IP-CIDR',
                      child: Text(c.tr('IP 範圍', 'IP range')),
                    ),
                    DropdownMenuItem(
                      value: 'PROCESS-NAME',
                      child: Text(c.tr('應用程式名稱', 'Application name')),
                    ),
                    DropdownMenuItem(
                      value: 'PROCESS-PATH',
                      child: Text(
                        c.tr('應用程式完整路徑', 'Application executable path'),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => type = v!),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: payload,
                  decoration: InputDecoration(
                    labelText: c.tr('條件', 'Match'),
                    hintText: type == 'IP-CIDR'
                        ? '192.168.0.0/16'
                        : type == 'PROCESS-NAME'
                        ? 'browser.exe'
                        : type == 'PROCESS-PATH'
                        ? c.tr('選擇應用程式執行檔', 'Choose an application executable')
                        : 'example.com',
                  ),
                ),
                if (type.startsWith('PROCESS-')) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: working
                        ? null
                        : () async {
                            try {
                              final path = await selectApplicationExecutable();
                              if (path == null || !context.mounted) {
                                return;
                              }
                              setState(() {
                                payload.text = type == 'PROCESS-NAME'
                                    ? path.split(RegExp(r'[/\\]')).last
                                    : path;
                                error = null;
                              });
                            } catch (e) {
                              if (context.mounted) {
                                setState(() => error = e.toString());
                              }
                            }
                          },
                    icon: const Icon(Icons.folder_open),
                    label: Text(c.tr('選擇應用程式', 'Choose application')),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    c.tr(
                      '請使用「代理所有應用程式」及規則模式。名稱比對會包含同名程序；使用不同執行檔的輔助程式需另加規則。新規則適用於新連線。',
                      'Use Proxy all applications and Rule mode. Name matches include all processes with that name; helpers with different executables need separate rules. New rules apply to new connections.',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: target,
                  decoration: InputDecoration(
                    labelText: c.tr('連線方式／節點', 'Route / node'),
                  ),
                  items: targets
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(
                            t == 'DIRECT'
                                ? c.tr('直連', 'Direct')
                                : t == 'REJECT'
                                ? c.tr('封鎖', 'Block')
                                : t,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => target = v!),
                ),
                const SizedBox(height: 12),
                Text(
                  c.tr(
                    '新規則會放在最前面，優先套用。',
                    'New rules are placed first and take priority.',
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(context),
              child: Text(c.tr('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      final value = payload.text.trim();
                      if (value.isEmpty ||
                          value.contains(',') ||
                          value.contains('\n')) {
                        setState(
                          () =>
                              error = c.tr('請輸入有效條件。', 'Enter a valid match.'),
                        );
                        return;
                      }
                      setState(() => working = true);
                      try {
                        await c.backend.call('patchProfile', {
                          'id': p.id,
                          'rule': '$type,$value,$target',
                          if (type.startsWith('PROCESS-'))
                            'changes': {'find-process-mode': 'strict'},
                        });
                        await c.refresh();
                        if (c.running) await c.loadRuntime();
                        if (context.mounted) Navigator.pop(context);
                      } catch (e) {
                        setState(() => error = e.toString());
                      } finally {
                        if (context.mounted) setState(() => working = false);
                      }
                    },
              child: Text(c.tr('新增並套用', 'Add and apply')),
            ),
          ],
        ),
      ),
    ),
  );
}

// The dialog route stays mounted while its dismissal animation runs. Own the
// text controller here rather than disposing it when showDialog completes.
class _RuleDialogHost extends StatefulWidget {
  const _RuleDialogHost({required this.builder});
  final Widget Function(BuildContext, TextEditingController) builder;

  @override
  State<_RuleDialogHost> createState() => _RuleDialogHostState();
}

class _RuleDialogHostState extends State<_RuleDialogHost> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, controller);
}

Future<void> showUpdateDialog(BuildContext context, AppController c) async {
  Json? info;
  final checked = await c.perform(() async {
    info = await c.backend.call('checkUpdates') as Json;
  });
  if (!checked || !context.mounted) return;
  final assets = (info!['core'] as Json)['assets'] as List? ?? [];
  final coreAsset = assets
      .cast<Json>()
      .where(
        (a) => (a['name'] as String).contains(
          Platform.isWindows
              ? 'windows'
              : Platform.isMacOS
              ? 'darwin'
              : 'linux',
        ),
      )
      .firstOrNull;
  final update = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(c.tr('版本更新', 'Version updates')),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.tr(
                '桌面程式由安裝包更新，核心可在這裡更新。',
                'Update the desktop app with its installer. Update the core here.',
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Aster Desktop · ${(info!['gui'] as Json?)?['tag_name'] ?? c.desktopVersion}',
            ),
            const SizedBox(height: 8),
            Text('Aster Core · ${coreAsset?['name'] ?? 'Prerelease-main'}'),
            const SizedBox(height: 12),
            Text(
              c.tr(
                '更新核心可能短暫中斷連線；失敗會回復舊版。',
                'Updating the core may briefly interrupt connections. A failed update restores the previous version.',
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
        OutlinedButton(
          onPressed: info!['guiUrl'] == null
              ? null
              : () => launchUrl(
                  Uri.parse(info!['guiUrl'] as String),
                  mode: LaunchMode.externalApplication,
                ),
          child: Text(
            info!['guiUrl'] == null
                ? c.tr('桌面版尚未發佈新版', 'No desktop release published')
                : c.tr('下載桌面新版', 'Download desktop update'),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(c.tr('更新核心', 'Update core')),
        ),
      ],
    ),
  );
  if (update == true) {
    await c.perform(() async {
      await c.backend.call('updateCore');
    });
  }
}
