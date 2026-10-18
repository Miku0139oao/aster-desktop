import 'package:window_manager/window_manager.dart';

/// Shared by a second launch, the tray menu, and native lifecycle tests.
Future<void> revealMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.show();
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.focus();
}
