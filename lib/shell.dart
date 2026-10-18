import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'pages.dart';
import 'application_rules.dart';
import 'brand.dart';
import 'workspace.dart';
import 'rules_page.dart';
import 'window_activation.dart';

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
  final Map<int, Widget> _pageViews = {};
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
      // Closing the last window does not terminate a macOS tray application.
      // Exit only after the bridge has stopped the core and restored settings.
      exit(0);
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
    unawaited(revealMainWindow());
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
    // Keep visited page state, but only rebuild the active page on telemetry.
    // Hidden large connection/node lists must not compete with log reading.
    if (c.ready) {
      _pageViews[c.page] = switch (c.page) {
        0 => OverviewPage(c: c),
        1 => NodesPage(c: c),
        2 => ProfilesPage(c: c),
        3 => ConnectionsPage(c: c),
        4 => LogsPage(c: c),
        6 => ApplicationsPage(c: c),
        7 => StatisticsPage(c: c),
        8 => DiagnosticsPage(c: c),
        9 => RulesPage(c: c),
        _ => AdvancedPage(c: c),
      };
    }
    final cs = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 1000;
    final destinations = [
      (0, Icons.space_dashboard_outlined, c.tr('首頁', 'Overview')),
      (1, Icons.hub_outlined, c.tr('節點', 'Nodes')),
      (2, Icons.folder_copy_outlined, c.tr('訂閱與設定', 'Profiles')),
      (6, Icons.apps_outlined, c.tr('應用程式', 'Applications')),
      (3, Icons.swap_calls, c.tr('連線', 'Connections')),
      (7, Icons.bar_chart_outlined, c.tr('統計', 'Statistics')),
      (9, Icons.alt_route, c.tr('規則', 'Rules')),
      (8, Icons.troubleshoot, c.tr('診斷', 'Diagnostics')),
      (4, Icons.receipt_long_outlined, c.tr('日誌', 'Logs')),
      (5, Icons.tune, c.tr('進階設定', 'Advanced')),
    ];
    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyK,
          control: !Platform.isMacOS,
          meta: Platform.isMacOS,
        ): () =>
            _jumpTo(destinations),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                Container(
                  width: compact ? 164 : 208,
                  color: cs.surfaceContainerLow,
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(18, 20, 18, 16),
                        child: Row(
                          children: [
                            const AsterMark(size: 30),
                            ...[
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Aster',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 23,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (var i = 0; i < destinations.length; i++) ...[
                              if (i == 0 || i == 4 || i == 7)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    10,
                                    12,
                                    6,
                                  ),
                                  child: Text(
                                    i == 0
                                        ? c.tr('日常使用', 'Everyday')
                                        : i == 4
                                        ? c.tr('活動與分流', 'Activity & routing')
                                        : c.tr('工具', 'Tools'),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 2,
                                ),
                                child: Tooltip(
                                  message: destinations[i].$3,
                                  child: Material(
                                    color: c.page == destinations[i].$1
                                        ? cs.secondaryContainer
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                    child: InkWell(
                                      key: ValueKey(
                                        'nav:${destinations[i].$1}',
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () =>
                                          c.navigate(destinations[i].$1),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 11,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          children: [
                                            Icon(
                                              destinations[i].$2,
                                              size: 20,
                                              color:
                                                  c.page == destinations[i].$1
                                                  ? cs.onSecondaryContainer
                                                  : cs.onSurfaceVariant,
                                            ),
                                            ...[
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  destinations[i].$3,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight:
                                                        c.page ==
                                                            destinations[i].$1
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
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                        child: Column(
                          children: [
                            if (c.active != null)
                              Tooltip(
                                message: c.active!.name,
                                child: Text(
                                  c.active!.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonalIcon(
                                key: const Key('sidebar-connect'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 12,
                                  ),
                                ),
                                onPressed:
                                    !c.ready || c.busy || c.active == null
                                    ? null
                                    : c.toggle,
                                icon: Icon(
                                  c.running
                                      ? Icons.stop_circle_outlined
                                      : Icons.play_arrow_rounded,
                                  size: 20,
                                ),
                                label: Text(
                                  c.running
                                      ? c.tr('停止代理', 'Stop proxy')
                                      : c.tr('啟動代理', 'Start proxy'),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'v${c.desktopVersion}',
                              style: TextStyle(fontSize: 11, color: cs.outline),
                            ),
                            if (widget.desktopLifecycle)
                              TextButton(
                                onPressed: _quit,
                                child: Text(
                                  c.tr('退出並停止代理', 'Quit and stop proxy'),
                                ),
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
                        padding: const EdgeInsets.fromLTRB(24, 16, 16, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    destinations
                                        .firstWhere((d) => d.$1 == c.page)
                                        .$3,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: c.tr('快速前往', 'Go to a page'),
                              onPressed: () => _jumpTo(destinations),
                              icon: const Icon(Icons.search),
                            ),
                            PopupMenuButton<String>(
                              tooltip: c.tr('外觀', 'Appearance'),
                              initialValue: c.settings.theme,
                              onSelected: (theme) =>
                                  c.saveSettings({'theme': theme}),
                              itemBuilder: (_) => [
                                for (final theme in [
                                  ('system', c.tr('跟隨系統', 'System')),
                                  ('light', c.tr('淺色', 'Light')),
                                  ('dark', c.tr('深色', 'Dark')),
                                ])
                                  CheckedPopupMenuItem(
                                    value: theme.$1,
                                    checked: c.settings.theme == theme.$1,
                                    enabled: !c.busy,
                                    child: Text(theme.$2),
                                  ),
                              ],
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
                            : IndexedStack(
                                index: c.page,
                                children: [
                                  for (var index = 0; index < 10; index++)
                                    if (!_pageViews.containsKey(index))
                                      const SizedBox.shrink()
                                    else
                                      TickerMode(
                                        enabled: c.page == index,
                                        child: _pageViews[index]!,
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
        ),
      ),
    );
  }

  Future<void> _jumpTo(List<(int, IconData, String)> destinations) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => _PagePicker(c: c, destinations: destinations),
    );
    if (mounted && selected != null) c.navigate(selected);
  }
}

class _PagePicker extends StatefulWidget {
  const _PagePicker({required this.c, required this.destinations});
  final AppController c;
  final List<(int, IconData, String)> destinations;
  @override
  State<_PagePicker> createState() => _PagePickerState();
}

class _PagePickerState extends State<_PagePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.destinations
        .where((d) => d.$3.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: Text(widget.c.tr('快速前往', 'Go to a page')),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const Key('navigation-search'),
              autofocus: true,
              decoration: InputDecoration(
                hintText: widget.c.tr(
                  '搜尋頁面 · Enter 開啟',
                  'Find a page · Enter to open',
                ),
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
              onSubmitted: (value) {
                final first = widget.destinations
                    .where(
                      (d) => d.$3.toLowerCase().contains(value.toLowerCase()),
                    )
                    .firstOrNull;
                if (first != null) {
                  Navigator.pop(context, first.$1);
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(widget.c.tr('找不到頁面', 'No matching pages')),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, i) => ListTile(
                        leading: Icon(matches[i].$2),
                        title: Text(matches[i].$3),
                        selected: widget.c.page == matches[i].$1,
                        onTap: () => Navigator.pop(context, matches[i].$1),
                      ),
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
    if (message.contains('tun outbound network')) {
      return c.tr(
        '所選出口網路未連接，請到首頁選擇可用的 Wi-Fi 或其他網路，再重新連線。',
        'The selected outbound network is unavailable. Choose an available Wi-Fi or other network on Home, then reconnect.',
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
