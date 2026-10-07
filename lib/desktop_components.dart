import 'package:flutter/material.dart';

import 'controller.dart';

class DesktopToolbar extends StatelessWidget {
  const DesktopToolbar({
    super.key,
    required this.c,
    required this.search,
    required this.hint,
    required this.onChanged,
    required this.actions,
    this.searchKey,
  });
  final AppController c;
  final TextEditingController search;
  final String hint;
  final ValueChanged<String> onChanged;
  final List<Widget> actions;
  final Key? searchKey;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final input = TextField(
          key: searchKey,
          controller: search,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            fillColor: Theme.of(context).colorScheme.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: c.tr('清除搜尋', 'Clear search'),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      search.clear();
                      onChanged('');
                    },
                  ),
          ),
        );
        final buttons = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        );
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth >= 850 * scale) {
          return Row(
            children: [
              Expanded(child: input),
              const SizedBox(width: 12),
              Flexible(flex: 2, child: buttons),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            input,
            if (actions.isNotEmpty) ...[const SizedBox(height: 8), buttons],
          ],
        );
      },
    ),
  );
}

class DetailBadge extends StatelessWidget {
  const DetailBadge(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ink = color ?? colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (color ?? colors.onSurface).withValues(alpha: .07),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: ink),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}
