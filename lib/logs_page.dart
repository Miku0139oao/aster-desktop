import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'desktop_components.dart';
import 'dialogs.dart' show exportText;
import 'inspection.dart';
import 'log_entry.dart';
import 'pages.dart' show EmptyMessage, sanitizeLogs;

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.c});
  final AppController c;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final search = TextEditingController(), scroll = ScrollController();
  final levels = <String>{};
  String source = '';
  List<String>? snapshot, previous;
  List<LogEntry> parsed = [];
  LogEntry? selected;
  AppController get c => widget.c;

  List<LogEntry> get records {
    final lines = snapshot ?? c.logs;
    if (!identical(previous, lines)) {
      previous = lines;
      parsed = lines.map(LogEntry.new).toList().reversed.toList();
    }
    return parsed;
  }

  void pause() => setState(() => snapshot = List.of(c.logs));
  void resume() {
    setState(() => snapshot = null);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  Future<void> copy(String value) async {
    await Clipboard.setData(ClipboardData(text: sanitizeLogs(value)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(c.tr('已複製', 'Copied')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Color levelColor(String level) => switch (level) {
    'error' => Theme.of(context).colorScheme.error,
    'warning' =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.amber.shade200
          : Colors.brown.shade700,
    _ => Theme.of(context).colorScheme.primary,
  };

  Map<String, String> fields(LogEntry entry) => {
    c.tr('時間', 'Time'): entry.timestamp,
    c.tr('層級', 'Level'): entry.level,
    c.tr('來源', 'Source'): entry.source,
    c.tr('訊息', 'Message'): entry.message,
    c.tr('原始日誌', 'Raw log'): entry.raw,
  };

  void inspect(LogEntry entry, bool split) {
    // Freeze the list while inspecting a record. Incoming logs stay buffered.
    if (snapshot == null) pause();
    if (split) {
      setState(() => selected = entry);
    } else {
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(c.tr('日誌詳情', 'Log details')),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: InspectionFields(fields: fields(entry)),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => copy(entry.raw),
              icon: const Icon(Icons.copy),
              label: Text(c.tr('複製這筆', 'Copy entry')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context),
              child: Text(c.tr('完成', 'Done')),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = records
        .where(
          (entry) =>
              (levels.isEmpty || levels.contains(entry.level)) &&
              (source.isEmpty || source == entry.source) &&
              entry.matches(search.text),
        )
        .toList();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final split =
              constraints.maxWidth >=
              880 * MediaQuery.textScalerOf(context).scale(14) / 14;
          final list = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopToolbar(
                c: c,
                search: search,
                searchKey: const Key('log-search'),
                hint: c.tr(
                  '搜尋日誌，可用多個關鍵字或 -排除',
                  'Search logs · multiple terms or -exclude',
                ),
                onChanged: (_) => setState(() {}),
                actions: [
                  IconButton(
                    tooltip: c.tr(
                      snapshot == null ? '暫停日誌更新' : '繼續日誌更新',
                      snapshot == null
                          ? 'Pause log updates'
                          : 'Resume log updates',
                    ),
                    onPressed: snapshot == null ? pause : resume,
                    icon: Icon(
                      snapshot == null ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  IconButton(
                    tooltip: c.tr('複製篩選結果', 'Copy filtered logs'),
                    onPressed: entries.isEmpty
                        ? null
                        : () => copy(
                            entries.reversed.map((e) => e.raw).join('\n'),
                          ),
                    icon: const Icon(Icons.copy_outlined),
                  ),
                  IconButton(
                    tooltip: c.tr('匯出篩選結果', 'Export filtered logs'),
                    onPressed: entries.isEmpty
                        ? null
                        : () => exportText(
                            context,
                            c,
                            sanitizeLogs(
                              entries.reversed.map((e) => e.raw).join('\n'),
                            ),
                            'aster-logs.txt',
                          ),
                    icon: const Icon(Icons.download_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: Text(c.tr('全部層級', 'All levels')),
                    selected: levels.isEmpty,
                    onSelected: (_) => setState(levels.clear),
                  ),
                  for (final level in ['error', 'warning', 'info', 'debug'])
                    FilterChip(
                      label: Text(
                        '${switch (level) {
                          'error' => c.tr('錯誤', 'Error'),
                          'warning' => c.tr('警告', 'Warning'),
                          'debug' => c.tr('除錯', 'Debug'),
                          _ => c.tr('資訊', 'Info'),
                        }} ${records.where((e) => e.level == level).length}',
                      ),
                      selected: levels.contains(level),
                      onSelected: (value) => setState(() {
                        if (value) {
                          levels.add(level);
                        } else {
                          levels.remove(level);
                        }
                      }),
                    ),
                  PopupMenuButton<String>(
                    tooltip: c.tr('日誌來源', 'Log source'),
                    onSelected: (value) => setState(() => source = value),
                    itemBuilder: (_) => [
                      for (final item in {
                        '': c.tr('全部來源', 'All sources'),
                        'core': c.tr('核心', 'Core'),
                        'desktop': c.tr('桌面程式', 'Desktop'),
                      }.entries)
                        CheckedPopupMenuItem(
                          value: item.key,
                          checked: source == item.key,
                          child: Text(item.value),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.filter_list, size: 16),
                      label: Text(
                        source.isEmpty ? c.tr('全部來源', 'All sources') : source,
                      ),
                    ),
                  ),
                  if (levels.isNotEmpty ||
                      search.text.isNotEmpty ||
                      source.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() {
                        levels.clear();
                        search.clear();
                        source = '';
                      }),
                      child: Text(c.tr('清除篩選', 'Reset filters')),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    Text(
                      c.tr(
                        '顯示 ${entries.length} / ${records.length} 筆',
                        '${entries.length} / ${records.length} entries',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (snapshot != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 24),
                        ),
                        onPressed: resume,
                        icon: const Icon(Icons.vertical_align_top, size: 16),
                        label: Text(
                          c.tr(
                            '查閱已暫停 · 回到即時日誌',
                            'Reading paused · return to live',
                          ),
                        ),
                      )
                    else
                      Text(
                        c.tr(
                          '最新在上 · 捲動查閱時自動暫停',
                          'Newest first · scrolling pauses updates',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? EmptyMessage(
                        icon: Icons.receipt_long_outlined,
                        title: c.tr(
                          records.isEmpty ? '目前沒有日誌' : '沒有符合的日誌',
                          records.isEmpty ? 'No logs yet' : 'No matching logs',
                        ),
                        detail: c.tr(
                          records.isEmpty ? '連線後會顯示核心日誌。' : '調整層級或清除搜尋條件。',
                          records.isEmpty
                              ? 'Core logs appear after connecting.'
                              : 'Change the selected levels or clear the search.',
                        ),
                        action: records.isEmpty
                            ? null
                            : TextButton(
                                onPressed: () => setState(() {
                                  levels.clear();
                                  search.clear();
                                  source = '';
                                }),
                                child: Text(c.tr('清除篩選', 'Reset filters')),
                              ),
                      )
                    : NotificationListener<UserScrollNotification>(
                        onNotification: (notification) {
                          if (notification.direction != ScrollDirection.idle &&
                              snapshot == null) {
                            pause();
                          }
                          return false;
                        },
                        child: Scrollbar(
                          controller: scroll,
                          child: ListView.builder(
                            controller: scroll,
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              return Material(
                                color: selected?.raw == entry.raw
                                    ? colors.secondaryContainer
                                    : index.isEven
                                    ? colors.surfaceContainerLow
                                    : colors.surface,
                                child: InkWell(
                                  onTap: () => inspect(entry, split),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 64,
                                          child: Text(
                                            entry.level.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: levelColor(entry.level),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (entry.timestamp.isNotEmpty)
                                                Text(
                                                  entry.timestamp,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        color: colors
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              Text(
                                                entry.message,
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ],
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              if (split && selected != null) ...[
                const VerticalDivider(width: 24),
                SizedBox(
                  width: 320,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.tr('日誌詳情', 'Log details'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: c.tr('關閉詳情', 'Close details'),
                            onPressed: () => setState(() => selected = null),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: InspectionFields(fields: fields(selected!)),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => copy(selected!.raw),
                        icon: const Icon(Icons.copy),
                        label: Text(c.tr('複製這筆', 'Copy entry')),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }
}
