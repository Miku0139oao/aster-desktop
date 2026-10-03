// Run: flutter test scripts/benchmark_yaml.dart
// Measures edit + widget frame time in the Windows debug test harness, not release FPS.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  testWidgets('YAML editor frame comparison', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1180, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final count in [1800, 10000]) {
      final content = List.generate(
        count,
        (i) =>
            '  - {name: Node $i, type: vless, server: example.test, port: 443, network: ws}',
      ).join('\n');
      final plain = TextEditingController(text: content);
      final code = CodeLineEditingController.fromText(content);
      for (final kind in ['TextField', 'CodeEditor']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 760,
                  height: 460,
                  child: kind == 'TextField'
                      ? TextField(
                          controller: plain,
                          maxLines: null,
                          expands: true,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 13,
                            height: 1.5,
                          ),
                        )
                      : CodeEditor(
                          controller: code,
                          wordWrap: false,
                          autocompleteSymbols: false,
                          style: const CodeEditorStyle(
                            fontFamily: 'Consolas',
                            fontSize: 13,
                            fontHeight: 1.5,
                          ),
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (kind == 'CodeEditor')
          code.selection = CodeLineSelection.collapsed(
            index: count - 1,
            offset: code.codeLines.last.text.length,
          );
        await tester.pumpAndSettle();
        final times = <int>[];
        for (var i = 0; i < 35; i++) {
          final watch = Stopwatch()..start();
          if (kind == 'TextField') {
            final text = '${plain.text}x';
            plain.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
          } else {
            code.replaceSelection('x');
          }
          await tester.pump();
          watch.stop();
          if (i >= 5) {
            times.add(watch.elapsedMicroseconds);
          }
        }
        times.sort();
        debugPrint(
          '$kind $count lines median=${(times[times.length ~/ 2] / 1000).toStringAsFixed(2)}ms p95=${(times[(times.length * .95).floor()] / 1000).toStringAsFixed(2)}ms (Flutter widget debug harness)',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      }
      plain.dispose();
      code.dispose();
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
