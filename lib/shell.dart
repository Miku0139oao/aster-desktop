import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'pages.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.desktopLifecycle = true,
  });
  final AppController controller;
  final bool desktopLifecycle;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener, TrayListener {
  AppController get c => widget.controller;
  bool _trayReady = false, _quitting = false;
  @override
  void initState() {
    super.initState();
    if (widget.desktopLifecycle) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      unawaited(_setupTray());
    }
  }

  Future<void> _setupTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/aster.ico' : 'assets/aster.png',
      );
      await trayManager.setToolTip('Aster Desktop');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Aster Desktop'),
            MenuItem(key: 'toggle', label: '連線 / 斷線 · Connect / Disconnect'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: '退出 / Quit'),
          ],
        ),
      );
      _trayReady = true;
      await windowManager.setPreventClose(true);
    } catch (_) {
      _trayReady = false;
      await windowManager.setPreventClose(true);
    }
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await c.backend.close();
      if (_trayReady) await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (e) {
      _quitting = false;
      c.error = e.toString();
      c.reportError(c.error);
      await windowManager.show();
    }
  }

  @override
  void onWindowClose() {
    if (_trayReady) {
      unawaited(windowManager.hide());
    } else {
      unawaited(_quit());
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        onTrayIconMouseDown();
      case 'toggle':
        unawaited(c.toggle());
      case 'quit':
        unawaited(_quit());
    }
  }

  @override
  void dispose() {
    if (widget.desktopLifecycle) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 940;
    final destinations = [
      (Icons.space_dashboard_outlined, c.tr('首頁', 'Overview')),
      (Icons.hub_outlined, c.tr('節點', 'Nodes')),
      (Icons.folder_copy_outlined, c.tr('訂閱與設定', 'Profiles')),
      (Icons.swap_calls, c.tr('連線', 'Connections')),
      (Icons.receipt_long_outlined, c.tr('日誌', 'Logs')),
      (Icons.tune, c.tr('進階設定', 'Advanced')),
    ];
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: compact ? 88 : 224,
              color: cs.surfaceContainerLow,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 18 : 24,
                      28,
                      compact ? 18 : 24,
                      24,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.auto_awesome,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                        if (!compact) ...[
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Aster',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'DESKTOP',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  for (var i = 0; i < destinations.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Tooltip(
                        message: destinations[i].$2,
                        child: Material(
                          color: c.page == i
                              ? cs.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => c.navigate(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 15,
                              ),
                              child: Row(
                                mainAxisAlignment: compact
                                    ? MainAxisAlignment.center
                                    : MainAxisAlignment.start,
                                children: [
                                  Icon(
                                    destinations[i].$1,
                                    color: c.page == i
                                        ? cs.onSecondaryContainer
                                        : cs.onSurfaceVariant,
                                  ),
                                  if (!compact) ...[
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        destinations[i].$2,
                                        style: TextStyle(
                                          fontWeight: c.page == i
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        if (!compact)
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: c.running ? cs.primary : cs.outline,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  c.running
                                      ? c.tr('代理運作中', 'Proxy is active')
                                      : c.tr('尚未連線', 'Disconnected'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 12),
                        Text(
                          compact
                              ? c.desktopVersion
                              : 'Aster Desktop ${c.desktopVersion}',
                          style: TextStyle(fontSize: 11, color: cs.outline),
                        ),
                        if (widget.desktopLifecycle)
                          TextButton(
                            onPressed: _quit,
                            child: Text(c.tr('退出', 'Quit')),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 26, 32, 18),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                destinations[c.page].$2,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                c.tr('讓連線變簡單。', 'A simpler way to connect.'),
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: c.tr(
                            '匯入訂閱或設定',
                            'Import subscription or configuration',
                          ),
                          onPressed: c.busy
                              ? null
                              : () => showImportDialog(context, c),
                          icon: const Icon(Icons.add),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: c.tr('外觀', 'Appearance'),
                          onPressed: c.busy
                              ? null
                              : () => c.saveSettings({
                                  'theme': c.settings.theme == 'dark'
                                      ? 'light'
                                      : 'dark',
                                }),
                          icon: Icon(
                            c.settings.theme == 'dark'
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (c.busy) const LinearProgressIndicator(minHeight: 2),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
                      child: ErrorCard(c: c),
                    ),
                  Expanded(
                    child: !c.ready
                        ? const Center(child: CircularProgressIndicator())
                        : switch (c.page) {
                            0 => OverviewPage(c: c),
                            1 => NodesPage(c: c),
                            2 => ProfilesPage(c: c),
                            3 => ConnectionsPage(c: c),
                            4 => LogsPage(c: c),
                            _ => AdvancedPage(c: c),
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.error_outline, color: cs.onErrorContainer),
        title: Text(
          c.tr(
            '操作未完成，現有設定已保留。',
            'The operation could not be completed. Your settings were kept.',
          ),
          style: TextStyle(color: cs.onErrorContainer),
        ),
        subtitle: Text(_hint()),
        trailing: IconButton(
          tooltip: c.tr('關閉', 'Dismiss'),
          icon: const Icon(Icons.close),
          onPressed: () {
            c.error = null;
            c.reportError(c.error);
          },
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .2,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    c.error ?? '',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _hint() {
    final message = (c.error ?? '').toLowerCase();
    if (message.contains('already running')) {
      return c.tr(
        '程式已在執行，請從系統托盤開啟。',
        'The app is already running. Open it from the tray.',
      );
    }
    if (message.contains('port') && message.contains('in use')) {
      return c.tr(
        '請停止其他代理，或到進階設定選擇其他連接埠。',
        'Stop the other proxy or choose another port in Advanced.',
      );
    }
    if (message.contains('waiting for controller') ||
        message.contains('remote providers')) {
      return c.tr(
        '核心仍在載入遠端規則或訂閱，請檢查網路與目前節點後重試。',
        'The core is loading remote rules or providers. Check your network and selected node, then retry.',
      );
    }
    if (message.contains('tun adapter')) {
      return c.tr(
        '全應用程式代理未能就緒；可先改用系統代理。請展開詳細原因檢查 TUN 設定及其他 VPN。',
        'TUN could not become ready. Try system proxy and expand the details to check TUN settings and other VPNs.',
      );
    }
    if (message.contains('service') ||
        message.contains('permission') ||
        message.contains('authorization') ||
        message.contains('approve')) {
      return c.service['installed'] == true
          ? c.tr(
              '背景服務已安裝。請確認服務正在執行及系統授權已完成。',
              'The background service is installed. Check that it is running and system authorization is approved.',
            )
          : c.tr(
              '請到進階設定安裝背景服務，並完成系統授權。',
              'Install the background service in Advanced and approve the system prompt.',
            );
    }
    if (message.contains('subscription') || message.contains('download')) {
      return c.tr(
        '請檢查訂閱網址與網路，再試一次。',
        'Check the subscription URL and your network, then try again.',
      );
    }
    if (message.contains('configuration') || message.contains('validation')) {
      return c.tr(
        '請檢查設定內容，或還原上一份有效設定。',
        'Check the configuration or restore its previous version.',
      );
    }
    return c.tr(
      '請稍後重試；點開這則訊息可查看詳細原因。',
      'Try again. Expand this message for details.',
    );
  }
}
