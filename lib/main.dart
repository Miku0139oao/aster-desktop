import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'backend.dart';
import 'controller.dart';
import 'shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1180, 800),
    minimumSize: Size(760, 580),
    center: true,
    title: 'Aster Desktop',
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  try {
    final backend = await ProcessBackend.start();
    final controller = AppController(backend);
    runApp(AsterApp(controller: controller));
    await controller.initialize();
    if (args.contains('--autostart') && controller.profiles.isNotEmpty) {
      await controller.toggle();
    }
  } catch (e) {
    runApp(
      MaterialApp(
        theme: asterTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.build_circle_outlined, size: 56),
                    const SizedBox(height: 24),
                    const Text(
                      'Aster Desktop 無法啟動 / Could not start',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '請重新安裝完整套件。\nReinstall the complete application package.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(e.toString()),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => exit(1),
                      child: const Text('關閉 / Close'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ThemeData asterTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff7652bf),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'NotoSansTC',
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .6),
    ),
  );
}

class AsterApp extends StatelessWidget {
  const AsterApp({
    super.key,
    required this.controller,
    this.desktopLifecycle = true,
  });
  final AppController controller;
  final bool desktopLifecycle;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      title: 'Aster Desktop',
      debugShowCheckedModeBanner: false,
      theme: asterTheme(Brightness.light),
      darkTheme: asterTheme(Brightness.dark),
      themeMode: controller.themeMode,
      locale: controller.settings.language == 'en'
          ? const Locale('en')
          : const Locale('zh', 'TW'),
      supportedLocales: const [Locale('en'), Locale('zh', 'TW')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AppShell(
        controller: controller,
        desktopLifecycle: desktopLifecycle,
      ),
    ),
  );
}
