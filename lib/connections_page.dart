import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'controller.dart';
import 'desktop_components.dart';
import 'dialogs.dart' show confirm;
import 'rules_page.dart';

enum ConnectionSort { recent, download, upload, application, destination }

const connectionColumns = [
  'destination',
  'application',
  'route',
  'traffic',
  'speed',
  'duration',
];
String connectionColumnLabel(AppController c, String id) => switch (id) {
  'destination' => c.tr('目的地', 'Destination'),
  'application' => c.tr('應用程式', 'Application'),
  'route' => c.tr('出口／規則', 'Route / rule'),
  'traffic' => c.tr('累計流量', 'Transferred'),
  'speed' => c.tr('即時速度', 'Speed'),
  _ => c.tr('持續時間', 'Duration'),
};

class ConnectionEntry {
  ConnectionEntry(this.data) {
    metadata = data['metadata'] as Map? ?? {};
    id = data['id'] as String;
    final host = (metadata['host'] as String? ?? '').trim();
    final target = host.isEmpty
        ? metadata['destinationIP'] as String? ?? '—'
        : host;
    final address = target.contains(':') && !target.startsWith('[')
        ? '[$target]'
        : target;
    destination = metadata['destinationPort'] == null
        ? address
        : '$address:${metadata['destinationPort']}';
    path = (metadata['processPath'] as String? ?? '').trim();
    final name = (metadata['process'] as String? ?? '').trim();
    application = name.isNotEmpty ? name : path.split(RegExp(r'[/\\]')).last;
    protocol = (metadata['network'] as String? ?? '').toUpperCase();
    route = (data['chains'] as List? ?? []).reversed.join(' → ');
    rule = '${data['rule'] ?? ''} ${data['rulePayload'] ?? ''}'.trim();
    started = DateTime.tryParse(data['start'] as String? ?? '');
    upload = data['upload'] as num? ?? 0;
    download = data['download'] as num? ?? 0;
    searchable =
        '$destination $application $path $protocol $route $rule $id ${metadata['sourceIP'] ?? ''} ${metadata['destinationIP'] ?? ''}'
            .toLowerCase();
  }
  final Json data;
  late final Map metadata;
  late final String id,
      destination,
      application,
      path,
      protocol,
      route,
      rule,
      searchable;
  late final DateTime? started;
  late final num upload, download;
}

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.c});
  final AppController c;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  final search = TextEditingController();
  ConnectionSort sort = ConnectionSort.recent;
  String protocol = 'all';
  String groupBy = '';
  List<String> get columns =>
      (c.preferences['connectionColumns'] as List? ??
              connectionColumns.take(4).toList())
          .cast<String>()
          .where(connectionColumns.contains)
          .toList();
  Map get weights => c.preferences['connectionWidths'] as Map? ?? {};
  int weight(String id) =>
      (weights[id] as num? ??
              (['destination', 'route'].contains(id) ? 240 : 160))
          .toInt()
          .clamp(64, 1000);

  Future<void> editColumns() async {
    final order = [
      ...columns,
      ...connectionColumns.where((id) => !columns.contains(id)),
    ];
    final selected = columns.toSet();
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(c.tr('連線欄位', 'Connection columns')),
          content: SizedBox(
            width: 420,
            height: 350,
            child: ReorderableListView(
              onReorderItem: (oldIndex, newIndex) => update(() {
                final item = order.removeAt(oldIndex);
                order.insert(newIndex, item);
              }),
              children: [
                for (final id in order)
                  CheckboxListTile(
                    key: ValueKey(id),
                    title: Text(connectionColumnLabel(c, id)),
                    value: selected.contains(id),
                    onChanged: (v) => update(
                      () => v == true ? selected.add(id) : selected.remove(id),
                    ),
                    secondary: const Icon(Icons.drag_handle),
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
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(c.tr('儲存', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await c.savePreferences({
        'connectionColumns': order.where(selected.contains).toList(),
      });
    }
  }

  List<ConnectionEntry>? paused;
  List? source;
  List<ConnectionEntry> live = [];
  final downHistory = <double>[], upHistory = <double>[];
  int? sampledAt;
  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    c.addListener(sample);
    sample();
  }

  void sample() {
    if (!c.running) {
      sampledAt = null;
      downHistory.clear();
      upHistory.clear();
      paused = null;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (sampledAt == now) return;
    sampledAt = now;
    downHistory.add(c.download);
    upHistory.add(c.upload);
    if (downHistory.length > 30) {
      downHistory.removeAt(0);
      upHistory.removeAt(0);
    }
  }

  List<ConnectionEntry> get records {
    final incoming = c.connections['connections'] as List? ?? const [];
    if (!identical(source, incoming) || live.length != incoming.length) {
      source = incoming;
      live = [for (final item in incoming) ConnectionEntry(item as Json)];
    }
    return paused ?? live;
  }

  List<ConnectionEntry> get filtered {
    final query = search.text.trim().toLowerCase();
    final entries = records
        .where(
          (e) =>
              (protocol == 'all' || e.protocol == protocol) &&
              e.searchable.contains(query),
        )
        .toList();
    entries.sort((a, b) {
      final order = switch (sort) {
        ConnectionSort.download => b.download.compareTo(a.download),
        ConnectionSort.upload => b.upload.compareTo(a.upload),
        ConnectionSort.application => a.application.toLowerCase().compareTo(
          b.application.toLowerCase(),
        ),
        ConnectionSort.destination => a.destination.toLowerCase().compareTo(
          b.destination.toLowerCase(),
        ),
        ConnectionSort.recent => (b.started ?? DateTime(1970)).compareTo(
          a.started ?? DateTime(1970),
        ),
      };
      return order != 0 ? order : a.id.compareTo(b.id);
    });
    return entries;
  }

  Future<void> close(List<ConnectionEntry> entries, {bool ask = false}) async {
    // Capture identities before a refresh changes the visible results.
    final ids = entries.map((e) => e.id).toSet();
    if (ask &&
        !await confirm(
          context,
          c,
          c.tr(
            '中止目前顯示的 ${ids.length} 條連線？',
            'Close the ${ids.length} displayed connections?',
          ),
        )) {
      return;
    }
    if (!mounted) return;
    final closed = <String>{};
    await c.perform(() async {
      for (final id in ids) {
        await c.api('DELETE', '/connections/${Uri.encodeComponent(id)}');
        closed.add(id);
      }
    });
    if (mounted && paused != null) {
      setState(() => paused!.removeWhere((e) => closed.contains(e.id)));
    }
  }

  String label(ConnectionSort value) => switch (value) {
    ConnectionSort.recent => c.tr('最新連線', 'Newest first'),
    ConnectionSort.download => c.tr('下載量', 'Download'),
    ConnectionSort.upload => c.tr('上傳量', 'Upload'),
    ConnectionSort.application => c.tr('應用程式', 'Application'),
    ConnectionSort.destination => c.tr('目的地', 'Destination'),
  };

  Future<void> details(ConnectionEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(c.tr('連線詳情', 'Connection details')),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final field in {
                c.tr('目的地', 'Destination'): entry.destination,
                c.tr('應用程式', 'Application'): entry.application.isEmpty
                    ? '—'
                    : entry.application,
                c.tr('執行檔路徑', 'Executable path'): entry.path.isEmpty
                    ? '—'
                    : entry.path,
                c.tr(
                  '連線來源',
                  'Source',
                ): '${entry.metadata['sourceIP'] ?? '—'}:${entry.metadata['sourcePort'] ?? ''}',
                c.tr('目的 IP', 'Destination IP'):
                    '${entry.metadata['destinationIP'] ?? '—'}',
                c.tr('協定／入口', 'Protocol / inbound'):
                    '${entry.protocol} · ${entry.metadata['type'] ?? '—'}',
                c.tr('出口鏈', 'Route chain'): entry.route.isEmpty
                    ? '—'
                    : entry.route,
                c.tr('命中規則', 'Matched rule'): entry.rule.isEmpty
                    ? '—'
                    : entry.rule,
                c.tr(
                  '下載／上傳',
                  'Download / upload',
                ): '${bytes(entry.download)} / ${bytes(entry.upload)} (${entry.download} / ${entry.upload} bytes)',
                c.tr('建立時間', 'Started'):
                    entry.started?.toLocal().toString() ?? '—',
                'ID': entry.id,
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        field.key,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(field.value),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: c.busy
              ? null
              : () {
                  Navigator.pop(context);
                  showRuleEditor(
                    this.context,
                    c,
                    path: entry.path,
                    application: entry.application,
                    host: entry.metadata['host'] as String?,
                    ip: entry.metadata['destinationIP'] as String?,
                  );
                },
          icon: const Icon(Icons.alt_route),
          label: Text(c.tr('建立分流規則', 'Create routing rule')),
        ),
        TextButton(
          onPressed: c.busy
              ? null
              : () async {
                  Navigator.pop(context);
                  await close([entry]);
                },
          child: Text(c.tr('中止連線', 'Close connection')),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context),
          child: Text(c.tr('完成', 'Done')),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entries = filtered;
    final colors = Theme.of(context).colorScheme;
    final indices = {for (var i = 0; i < entries.length; i++) entries[i].id: i};
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final wide = constraints.maxWidth >= 850 * scale;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _TrafficStat(
                          title: c.tr('下載速度', 'Download speed'),
                          icon: Icons.south_west,
                          value: '${bytes(c.running ? c.download : 0)}/s',
                          total: c.running
                              ? c.connections['downloadTotal'] as num?
                              : null,
                          c: c,
                          history: [...downHistory],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _TrafficStat(
                          title: c.tr('上傳速度', 'Upload speed'),
                          icon: Icons.north_east,
                          value: '${bytes(c.running ? c.upload : 0)}/s',
                          total: c.running
                              ? c.connections['uploadTotal'] as num?
                              : null,
                          c: c,
                          history: [...upHistory],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _TrafficStat(
                          title: c.tr('活動連線', 'Active connections'),
                          icon: Icons.swap_calls,
                          value: '${c.running ? live.length : 0}',
                          subtitle: c.running
                              ? c.tr(
                                  '符合篩選 ${entries.length} 條',
                                  '${entries.length} matching',
                                )
                              : c.tr('尚未連線', 'Disconnected'),
                          c: c,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PinnedHeaderSliver(
                child: ColoredBox(
                  color: colors.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DesktopToolbar(
                        c: c,
                        search: search,
                        hint: c.tr(
                          '搜尋程式、目的地、出口或規則',
                          'Search app, destination, route or rule',
                        ),
                        onChanged: (_) => setState(() {}),
                        actions: [
                          IconButton(
                            tooltip: c.tr(
                              '欄位顯示與順序',
                              'Column visibility and order',
                            ),
                            onPressed: editColumns,
                            icon: const Icon(Icons.view_column_outlined),
                          ),
                          PopupMenuButton<ConnectionSort>(
                            tooltip: c.tr('排序', 'Sort'),
                            initialValue: sort,
                            onSelected: (value) => setState(() => sort = value),
                            itemBuilder: (_) => [
                              for (final value in ConnectionSort.values)
                                CheckedPopupMenuItem(
                                  value: value,
                                  checked: value == sort,
                                  child: Text(label(value)),
                                ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.sort, size: 18),
                                  const SizedBox(width: 6),
                                  Text(label(sort)),
                                  const Icon(Icons.arrow_drop_down),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: c.tr(
                              paused == null ? '暫停列表更新' : '繼續列表更新',
                              paused == null
                                  ? 'Pause list updates'
                                  : 'Resume list updates',
                            ),
                            onPressed: !c.running
                                ? null
                                : () => setState(
                                    () => paused = paused == null
                                        ? [...records]
                                        : null,
                                  ),
                            icon: Icon(
                              paused == null ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: !c.running || c.busy || entries.isEmpty
                                ? null
                                : () => close(entries, ask: true),
                            icon: const Icon(Icons.close, size: 18),
                            label: Text(c.tr('中止篩選連線', 'Close displayed')),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final value in ['all', 'TCP', 'UDP'])
                              ChoiceChip(
                                label: Text(
                                  value == 'all'
                                      ? c.tr('全部協定', 'All protocols')
                                      : value,
                                ),
                                selected: protocol == value,
                                onSelected: (_) =>
                                    setState(() => protocol = value),
                              ),
                            PopupMenuButton<String>(
                              tooltip: c.tr('彙整方式', 'Group activity'),
                              onSelected: (v) => setState(() => groupBy = v),
                              itemBuilder: (_) => [
                                for (final entry in {
                                  '': c.tr('逐條連線', 'Individual connections'),
                                  'application': c.tr(
                                    '依應用程式彙整',
                                    'Group by application',
                                  ),
                                  'route': c.tr('依出口彙整', 'Group by route'),
                                }.entries)
                                  PopupMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                              ],
                              child: Chip(
                                label: Text(
                                  groupBy == ''
                                      ? c.tr('逐條連線', 'Individual connections')
                                      : groupBy == 'application'
                                      ? c.tr('依應用程式彙整', 'By application')
                                      : c.tr('依出口彙整', 'By route'),
                                ),
                              ),
                            ),
                            if (paused != null)
                              Text(
                                c.tr(
                                  '列表已暫停，流量仍即時更新',
                                  'List paused · traffic stays live',
                                ),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.primary),
                              ),
                          ],
                        ),
                      ),
                      if (wide &&
                          c.running &&
                          entries.isNotEmpty &&
                          groupBy.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(12),
                            ),
                          ),
                          child: Row(
                            children: [
                              for (final id in columns)
                                _header(
                                  connectionColumnLabel(c, id),
                                  switch (id) {
                                    'destination' => ConnectionSort.destination,
                                    'application' => ConnectionSort.application,
                                    'traffic' => ConnectionSort.download,
                                    _ => null,
                                  },
                                  weight(id),
                                  id,
                                ),
                              const SizedBox(width: 96),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!c.running || entries.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          !c.running
                              ? Icons.swap_calls
                              : Icons.filter_alt_off_outlined,
                          size: 40,
                          color: colors.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          !c.running
                              ? c.tr(
                                  '連線後查看活動連線',
                                  'View activity after connecting',
                                )
                              : records.isEmpty
                              ? c.tr('目前沒有活動連線', 'No active connections')
                              : c.tr('沒有符合篩選的連線', 'No matching connections'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          c.tr(
                            '流量累計以本次核心啟動為準，包含已結束的連線。',
                            'Totals cover this core session, including closed connections.',
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              else if (groupBy.isNotEmpty)
                SliverList.list(
                  children: [
                    for (final entry in _groups(entries).entries)
                      ListTile(
                        title: Text(
                          entry.key.isEmpty ? c.tr('未知', 'Unknown') : entry.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.value.length} ${c.tr('條活動連線', 'active connections')} · ↓ ${bytes(entry.value.fold<num>(0, (sum, e) => sum + e.download))} ↑ ${bytes(entry.value.fold<num>(0, (sum, e) => sum + e.upload))}',
                        ),
                        onTap: () => setState(() {
                          search.text = entry.key;
                          groupBy = '';
                        }),
                        trailing: IconButton(
                          tooltip: c.tr('中止此組連線', 'Close this group'),
                          onPressed: c.busy
                              ? null
                              : () => close(entry.value, ask: true),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                  ],
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final entry = entries[index];
                      return ConnectionRow(
                        key: ValueKey(entry.id),
                        c: c,
                        entry: entry,
                        wide: wide,
                        onDetails: () => details(entry),
                        onClose: c.busy ? null : () => close([entry]),
                        columns: columns,
                        weights: weights,
                      );
                    },
                    childCount: entries.length,
                    findChildIndexCallback: (key) =>
                        key is ValueKey<String> ? indices[key.value] : null,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }

  Map<String, List<ConnectionEntry>> _groups(List<ConnectionEntry> entries) {
    final result = <String, List<ConnectionEntry>>{};
    for (final entry in entries) {
      (result[groupBy == 'application' ? entry.application : entry.route] ??=
              [])
          .add(entry);
    }
    return result;
  }

  Widget _header(String title, ConnectionSort? value, int flex, String id) =>
      Expanded(
        flex: flex,
        child: InkWell(
          onTap: value == null ? null : () => setState(() => sort = value),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (value != null && sort == value)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    value == ConnectionSort.application ||
                            value == ConnectionSort.destination
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    size: 13,
                  ),
                ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => setState(
                  () => c.preferences['connectionWidths'] = {
                    ...weights,
                    id: (weight(id) + details.delta.dx.round() * 2).clamp(
                      64,
                      1000,
                    ),
                  },
                ),
                onHorizontalDragEnd: (_) => c.savePreferences({
                  'connectionWidths': {...weights},
                }),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 5),
                  child: Icon(Icons.drag_indicator, size: 14),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    c.removeListener(sample);
    search.dispose();
    super.dispose();
  }
}

class ConnectionRow extends StatelessWidget {
  const ConnectionRow({
    super.key,
    required this.c,
    required this.entry,
    required this.wide,
    required this.onDetails,
    this.onClose,
    this.columns = const ['destination', 'application', 'route', 'traffic'],
    this.weights = const {},
  });
  final AppController c;
  final ConnectionEntry entry;
  final bool wide;
  final VoidCallback onDetails;
  final VoidCallback? onClose;
  final List<String> columns;
  final Map weights;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget text(String value, {bool secondary = false}) => Tooltip(
      message: value,
      child: GestureDetector(
        onSecondaryTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(c.tr('已複製', 'Copied')),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: Text(
          value.isEmpty ? '—' : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: secondary
              ? Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant)
              : Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
    final traffic = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        text('↓ ${bytes(entry.download)}'),
        const SizedBox(height: 4),
        text('↑ ${bytes(entry.upload)}', secondary: true),
        text(
          '↓ ${bytes(c.connectionRates[entry.id]?.$2 ?? 0)}/s  ↑ ${bytes(c.connectionRates[entry.id]?.$1 ?? 0)}/s',
          secondary: true,
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: c.tr('連線詳情', 'Connection details'),
          onPressed: onDetails,
          icon: const Icon(Icons.more_horiz, size: 19),
        ),
        IconButton(
          tooltip: c.tr('中止連線', 'Close connection'),
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    );
    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onDetails,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
          ),
          child: wide
              ? Row(
                  children: [
                    for (final id in columns)
                      Expanded(
                        flex:
                            (weights[id] as num? ??
                                    (['destination', 'route'].contains(id)
                                        ? 240
                                        : 160))
                                .toInt()
                                .clamp(64, 1000),
                        child: switch (id) {
                          'destination' => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              text(entry.destination),
                              const SizedBox(height: 4),
                              text(
                                '${entry.protocol} · ${entry.started == null ? '—' : '${DateTime.now().difference(entry.started!).inSeconds.clamp(0, 1 << 31)} s'}',
                                secondary: true,
                              ),
                            ],
                          ),
                          'application' => text(
                            entry.application.isEmpty
                                ? c.tr('未知程式', 'Unknown app')
                                : entry.application,
                          ),
                          'route' => Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                text(entry.route),
                                const SizedBox(height: 4),
                                text(entry.rule, secondary: true),
                              ],
                            ),
                          ),
                          'traffic' => traffic,
                          'speed' => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              text(
                                '↓ ${bytes(c.connectionRates[entry.id]?.$2 ?? 0)}/s',
                              ),
                              text(
                                '↑ ${bytes(c.connectionRates[entry.id]?.$1 ?? 0)}/s',
                                secondary: true,
                              ),
                            ],
                          ),
                          _ => text(
                            entry.started == null
                                ? '—'
                                : '${DateTime.now().difference(entry.started!).inSeconds.clamp(0, 1 << 31)} s',
                          ),
                        },
                      ),
                    SizedBox(width: 96, child: actions),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: text(entry.destination)),
                        const SizedBox(width: 8),
                        if (entry.protocol.isNotEmpty)
                          DetailBadge(entry.protocol),
                        actions,
                      ],
                    ),
                    const SizedBox(height: 4),
                    text(
                      '${entry.application.isEmpty ? c.tr('未知程式', 'Unknown app') : entry.application} · ${entry.route}',
                      secondary: true,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: text(entry.rule, secondary: true)),
                        const SizedBox(width: 10),
                        text(
                          '↓ ${bytes(entry.download)}   ↑ ${bytes(entry.upload)}',
                          secondary: true,
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TrafficStat extends StatelessWidget {
  const _TrafficStat({
    required this.title,
    required this.value,
    required this.icon,
    required this.c,
    this.total,
    this.subtitle,
    this.history,
  });
  final String title, value;
  final IconData icon;
  final AppController c;
  final num? total;
  final String? subtitle;
  final List<double>? history;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Tooltip(
            message: c.tr(
              '核心重新啟動後累計歸零；包含已結束連線的流量',
              'Totals reset when the core restarts and include closed connections',
            ),
            child: Text(
              subtitle ??
                  '${c.tr('累計', 'Total')} ${total == null ? '—' : bytes(total!)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 18,
            width: double.infinity,
            child: history == null
                ? const SizedBox()
                : CustomPaint(painter: _RatePainter(history!, colors.primary)),
          ),
        ],
      ),
    );
  }
}

class _RatePainter extends CustomPainter {
  _RatePainter(this.samples, this.color);
  final List<double> samples;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final peak = math.max(1.0, samples.reduce(math.max));
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = samples.length == 1
          ? 0.0
          : size.width * i / (samples.length - 1);
      final y = size.height - 2 - samples[i] / peak * (size.height - 4);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .65)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_RatePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}
