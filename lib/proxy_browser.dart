import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'desktop_components.dart';

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
    this.current,
    this.onTest,
    this.onReset,
  });
  final String id, title, detail;
  final String? current;
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
      Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final value in [false, true])
              IconButton(
                tooltip: c.tr(
                  value ? '列表排列' : '卡片排列',
                  value ? 'List view' : 'Card view',
                ),
                isSelected: list == value,
                style: IconButton.styleFrom(
                  backgroundColor: list == value
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => onLayout(value),
                icon: Icon(
                  value ? Icons.view_list_outlined : Icons.grid_view_outlined,
                  size: 19,
                ),
              ),
          ],
        ),
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
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        for (final section in widget.sections)
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 16),
            sliver: DecoratedSliver(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: widget.c.tr(
                              folded(section) ? '展開群組' : '收起群組',
                              folded(section)
                                  ? 'Expand group'
                                  : 'Collapse group',
                            ),
                            onPressed: () => setState(
                              () => collapsed.contains(section.id)
                                  ? collapsed.remove(section.id)
                                  : collapsed.add(section.id),
                            ),
                            icon: Icon(
                              folded(section)
                                  ? Icons.chevron_right
                                  : Icons.expand_more,
                              size: 20,
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(
                                () => collapsed.contains(section.id)
                                    ? collapsed.remove(section.id)
                                    : collapsed.add(section.id),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          section.title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      DetailBadge('${section.choices.length}'),
                                    ],
                                  ),
                                  if (section.current != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        '${widget.c.tr('目前', 'Current')} · ${section.current}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: colors.primary),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    )
                                  else if (section.detail.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        section.detail,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
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
                              icon: const Icon(Icons.autorenew, size: 19),
                            ),
                          if (section.onTest != null)
                            IconButton(
                              tooltip: widget.c.tr('測試此群組', 'Test this group'),
                              onPressed: section.onTest,
                              icon: const Icon(Icons.speed_outlined, size: 19),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!folded(section))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          final choices = sortProxyChoices(
                            section.choices,
                            widget.sort,
                          );
                          final columns = widget.list
                              ? 1
                              : math.max(
                                  1,
                                  math.min(
                                    5,
                                    (constraints.crossAxisExtent /
                                            (250 * math.min(scale, 1.5)))
                                        .floor(),
                                  ),
                                );
                          return SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  mainAxisExtent:
                                      (widget.list ? 76 : 104) *
                                      math.max(1, scale),
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => ProxyChoiceCard(
                                key: ValueKey(choices[index].id),
                                c: widget.c,
                                choice: choices[index],
                                list: widget.list,
                              ),
                              childCount: choices.length,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }
}

class ProxyChoiceCard extends StatelessWidget {
  const ProxyChoiceCard({
    super.key,
    required this.c,
    required this.choice,
    this.list = false,
  });
  final AppController c;
  final ProxyChoice choice;
  final bool list;

  String get detail => choice.detail
      .replaceAll('Selector', c.tr('手動選擇', 'Select'))
      .replaceAll('URLTest', c.tr('自動測速', 'Auto'))
      .replaceAll('Fallback', c.tr('故障切換', 'Fallback'));

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final delayColor = choice.delay == 0
        ? colors.error
        : choice.delay != null && choice.delay! > 500
        ? colors.tertiary
        : colors.primary;
    final title = Row(
      children: [
        Expanded(
          child: Tooltip(
            message: choice.name,
            child: Text(
              choice.name,
              maxLines: list ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        if (choice.selected) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_circle, color: colors.primary, size: 18),
        ],
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (choice.onOpen != null)
          IconButton(
            tooltip: c.tr('瀏覽群組節點', 'Browse group nodes'),
            onPressed: choice.onOpen,
            icon: const Icon(Icons.chevron_right, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        if (choice.onTest != null || choice.delay != null || choice.testing)
          Tooltip(
            message: c.tr('測試此節點', 'Test this node'),
            child: InkWell(
              onTap: choice.testing ? null : choice.onTest,
              borderRadius: BorderRadius.circular(7),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: choice.testing
                    ? const SizedBox(
                        width: 44,
                        height: 18,
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : DetailBadge(
                        choice.delay == null
                            ? '—'
                            : choice.delay == 0
                            ? c.tr('逾時', 'Timeout')
                            : '${choice.delay} ms',
                        color: delayColor,
                        icon: choice.delay == null
                            ? Icons.speed_outlined
                            : null,
                      ),
              ),
            ),
          ),
      ],
    );
    final subtitle = Tooltip(
      message: detail,
      child: Text(
        detail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: colors.onSurfaceVariant),
      ),
    );
    return Semantics(
      selected: choice.selected,
      child: Material(
        color: choice.selected
            ? colors.primaryContainer.withValues(alpha: .5)
            : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(
            color: choice.selected
                ? colors.primary.withValues(alpha: .4)
                : colors.outlineVariant.withValues(alpha: .3),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: choice.onSelect,
          onSecondaryTap: choice.onTest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: list
                ? Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            title,
                            const SizedBox(height: 4),
                            subtitle,
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      Row(
                        children: [
                          Expanded(child: subtitle),
                          const SizedBox(width: 6),
                          actions,
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
