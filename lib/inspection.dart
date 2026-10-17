import 'package:flutter/material.dart';

import 'controller.dart';

/// Literal terms combine with AND; quotes group a phrase, - excludes a term.
/// A supported field prefix restricts matching instead of searching labels.
bool matchesInspectionQuery(
  String query,
  String text, [
  Map<String, String> fields = const {},
]) {
  for (final match in RegExp(
    r'(-?)(?:(\w+):)?(?:"([^"]*)"|(\S+))',
  ).allMatches(query.toLowerCase())) {
    final field = match[2];
    final term = match[3] ?? match[4] ?? '';
    if (term.isEmpty) continue;
    final haystack = field != null && fields.containsKey(field)
        ? fields[field]!
        : text;
    final needle = field != null && !fields.containsKey(field)
        ? '$field:$term'
        : term;
    final found = haystack.toLowerCase().contains(needle);
    if (match[1] == '-' ? found : !found) return false;
  }
  return true;
}

Future<String?> pickInspectionFacet(
  BuildContext context,
  AppController c,
  String title,
  Iterable<String> values,
  String selected,
) async {
  final choices = values.where((v) => v.isNotEmpty).toSet().toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return showDialog<String>(
    context: context,
    builder: (_) =>
        _FacetPicker(c: c, title: title, choices: choices, selected: selected),
  );
}

class _FacetPicker extends StatefulWidget {
  const _FacetPicker({
    required this.c,
    required this.title,
    required this.choices,
    required this.selected,
  });
  final AppController c;
  final String title, selected;
  final List<String> choices;
  @override
  State<_FacetPicker> createState() => _FacetPickerState();
}

class _FacetPickerState extends State<_FacetPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final choices = widget.choices
        .where((v) => v.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                hintText: widget.c.tr('搜尋選項', 'Search options'),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
            ListTile(
              title: Text(widget.c.tr('全部', 'All')),
              selected: widget.selected.isEmpty,
              onTap: () => Navigator.pop(context, ''),
            ),
            Expanded(
              child: choices.isEmpty
                  ? Center(
                      child: Text(
                        widget.c.tr('沒有符合的選項', 'No matching options'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: choices.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        title: Text(choices[index]),
                        selected: widget.selected == choices[index],
                        onTap: () => Navigator.pop(context, choices[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.c.tr('取消', 'Cancel')),
        ),
      ],
    );
  }
}

class InspectionFields extends StatelessWidget {
  const InspectionFields({super.key, required this.fields});
  final Map<String, String> fields;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final field in fields.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                field.key,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(field.value.isEmpty ? '—' : field.value),
            ],
          ),
        ),
    ],
  );
}
