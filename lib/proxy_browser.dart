import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';

enum ProxySort { configuration, latency, name }

class ProxyChoice {
  const ProxyChoice({
    required this.id,
    required this.name,
    required this.detail,
    this.selected = false,
    this.delay,
    this.testing = false,
    this.onSelect,
    this.onTest,
    this.onOpen,
  });
  final String id, name, detail;
  final bool selected, testing;
  final int? delay;
  final VoidCallback? onSelect, onTest, onOpen;
}

class ProxySection {
  const ProxySection({
    required this.id,
    required this.title,
    required this.choices,
    this.detail = '',
    this.onTest,
    this.onReset,
  });
  final String id, title, detail;
  final List<ProxyChoice> choices;
  final VoidCallback? onTest;
  final VoidCallback? onReset;
}

List<ProxyChoice> sortProxyChoices(List<ProxyChoice> choices, ProxySort sort) {
  if (sort == ProxySort.configuration) return choices;
  final positions = {for (var i = 0; i < choices.length; i++) choices[i].id: i};
  return [...choices]..sort((a, b) {
    final comparison = sort == ProxySort.name
        ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
        : (a.delay == null
                  ? 1 << 30
                  : a.delay == 0
                  ? (1 << 30) + 1
                  : a.delay!)
              .compareTo(
                b.delay == null
                    ? 1 << 30
                    : b.delay == 0
                    ? (1 << 30) + 1
                    : b.delay!,
              );
    return comparison != 0
        ? comparison
        : positions[a.id]!.compareTo(positions[b.id]!);
  });
}

class ProxyBrowserControls extends StatelessWidget {
  const ProxyBrowserControls({
    super.key,
    required this.c,
    required this.sort,
    required this.list,
    required this.onSort,
    required this.onLayout,
  });
  final AppController c;
  final ProxySort sort;
  final bool list;
  final ValueChanged<ProxySort> onSort;
  final ValueChanged<bool> onLayout;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      PopupMenuButton<ProxySort>(
        tooltip: c.tr('排序', 'Sort'),
        initialValue: sort,
        onSelected: onSort,
        itemBuilder: (_) => [
          for (final entry in {
            ProxySort.configuration: c.tr('設定順序', 'Configuration order'),
            ProxySort.latency: c.tr('延遲由低到高', 'Lowest latency first'),
            ProxySort.name: c.tr('名稱排序', 'Name order'),
          }.entries)
            CheckedPopupMenuItem(
              value: entry.key,
              checked: sort == entry.key,
              child: Text(entry.value),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort, size: 20),
              const SizedBox(width: 6),
              Text(switch (sort) {
                ProxySort.configuration => c.tr('設定順序', 'Configuration order'),
                ProxySort.latency => c.tr('延遲排序', 'Latency order'),
                ProxySort.name => c.tr('名稱排序', 'Name order'),
              }),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
      IconButton(
        tooltip: c.tr(list ? '卡片排列' : '列表排列', list ? 'Card view' : 'List view'),
        onPressed: () => onLayout(!list),
        icon: Icon(list ? Icons.grid_view : Icons.view_list),
      ),
    ],
  );
}

/// Each group's children are created only when they approach the viewport.
class ProxyBrowser extends StatefulWidget {
  const ProxyBrowser({
    super.key,
    required this.c,
    required this.sections,
    this.sort = ProxySort.configuration,
    this.list = false,
    this.searching = false,
  });
  final AppController c;
  final List<ProxySection> sections;
  final ProxySort sort;
  final bool list, searching;
  @override
  State<ProxyBrowser> createState() => _ProxyBrowserState();
}

class _ProxyBrowserState extends State<ProxyBrowser> {
  final collapsed = <String>{};
  bool folded(ProxySection section) =>
      !widget.searching && collapsed.contains(section.id);
  @override
  Widget build(BuildContext context) {
    if (widget.sections.isEmpty) {
      return Center(child: Text(widget.c.tr('沒有符合的節點', 'No matching nodes')));
    }
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return CustomScrollView(
      slivers: [
        for (final section in widget.sections) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => setState(
                          () => collapsed.contains(section.id)
                              ? collapsed.remove(section.id)
                              : collapsed.add(section.id),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Icon(
                                folded(section)
                                    ? Icons.chevron_right
                                    : Icons.expand_more,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${section.title} · ${section.choices.length}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (section.detail.isNotEmpty)
                                      Text(
                                        section.detail,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (section.onReset != null)
                      IconButton(
                        tooltip: widget.c.tr(
                          '恢復自動選擇',
                          'Restore automatic selection',
                        ),
                        onPressed: section.onReset,
                        icon: const Icon(Icons.autorenew),
                      ),
                    if (section.onTest != null)
                      IconButton(
                        tooltip: widget.c.tr('測試此群組', 'Test this group'),
                        onPressed: section.onTest,
                        icon: const Icon(Icons.speed),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!folded(section))
            SliverLayoutBuilder(
              builder: (context, constraints) {
                final choices = sortProxyChoices(section.choices, widget.sort);
                final columns = widget.list
                    ? 1
                    : math.max(
                        1,
                        math.min(
                          6,
                          (constraints.crossAxisExtent /
                                  (225 * math.min(scale, 1.5)))
                              .floor(),
                        ),
                      );
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: 92 * math.max(1, scale),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => ProxyChoiceCard(
                      key: ValueKey(choices[index].id),
                      c: widget.c,
                      choice: choices[index],
                    ),
                    childCount: choices.length,
                  ),
                );
              },
            ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

class ProxyChoiceCard extends StatelessWidget {
  const ProxyChoiceCard({super.key, required this.c, required this.choice});
  final AppController c;
  final ProxyChoice choice;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final delayColor = choice.delay == 0
        ? colors.error
        : choice.delay != null && choice.delay! > 500
        ? colors.tertiary
        : colors.primary;
    return Semantics(
      selected: choice.selected,
      child: Material(
        color: choice.selected
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: choice.selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: choice.onSelect,
          onSecondaryTap: choice.onTest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: choice.name,
                          child: Text(
                            choice.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ),
                      if (choice.selected)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.check_circle,
                            color: colors.primary,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: choice.detail,
                        child: Text(
                          choice.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    if (choice.onOpen != null)
                      IconButton(
                        tooltip: c.tr('瀏覽群組節點', 'Browse group nodes'),
                        onPressed: choice.onOpen,
                        icon: const Icon(Icons.chevron_right),
                        visualDensity: VisualDensity.compact,
                      ),
                    if (choice.onTest != null ||
                        choice.delay != null ||
                        choice.testing)
                      TextButton(
                        onPressed: choice.testing ? null : choice.onTest,
                        style: TextButton.styleFrom(
                          foregroundColor: delayColor,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(40, 36),
                        ),
                        child: choice.testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                choice.delay == null
                                    ? c.tr('測速', 'Test')
                                    : choice.delay == 0
                                    ? c.tr('逾時', 'Timeout')
                                    : '${choice.delay} ms',
                              ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
