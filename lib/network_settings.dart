import 'package:flutter/material.dart';

import 'controller.dart';

class TunNetworkSelector extends StatefulWidget {
  const TunNetworkSelector({super.key, required this.controller});
  final AppController controller;

  @override
  State<TunNetworkSelector> createState() => _TunNetworkSelectorState();
}

class _TunNetworkSelectorState extends State<TunNetworkSelector> {
  List<String> _names = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result =
          await widget.controller.backend.call('listNetworkInterfaces') as List;
      if (!mounted) return;
      setState(() {
        _names = result
            .map((entry) => entry['name'] as String)
            .toSet()
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = widget.controller.tr(
          '無法讀取網路清單，請重新整理。',
          'Could not list networks. Refresh to try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final selected = c.settings.tunInterface;
    final missing = selected.isNotEmpty && !_names.contains(selected);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('tun-network:$selected:${_names.join('|')}'),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: c.tr('出口網路', 'Outbound network'),
                    prefixIcon: const Icon(Icons.router_outlined),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        c.tr('自動（依系統路由）', 'Automatic (system routes)'),
                      ),
                    ),
                    for (final name in _names)
                      DropdownMenuItem(value: name, child: Text(name)),
                    if (missing)
                      DropdownMenuItem(
                        value: selected,
                        enabled: false,
                        child: Text(
                          '$selected ${c.tr('（未連接）', '(unavailable)')}',
                        ),
                      ),
                  ],
                  onChanged: c.running || c.busy || _loading
                      ? null
                      : (value) {
                          if (value != null) {
                            c.saveSettings({'tunInterface': value});
                          }
                        },
                ),
              ),
              IconButton(
                tooltip: c.tr('重新整理網路', 'Refresh networks'),
                onPressed: _loading || c.busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _error ??
                (missing && !_loading
                    ? c.tr(
                        '所選網路未連接，請選擇其他網路後再連線。',
                        'The selected network is unavailable. Choose another before connecting.',
                      )
                    : c.tr(
                        'TUN 透過此網路連接節點。有線網路無法上網時，可選 Wi-Fi；自動選擇不會檢查網際網路是否可用。更改前請先停止代理。',
                        'TUN connects to nodes through this network. Choose Wi-Fi if Ethernet has no internet. Automatic selection does not check internet access. Stop the proxy before changing this.',
                      )),
          ),
        ],
      ),
    );
  }
}
