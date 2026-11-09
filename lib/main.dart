import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bootstrap.dart';
import 'theme/app_theme.dart';
import 'ui/app.dart';
import 'ui/startup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppFonts.configure();
  // Edge to edge: the stone background runs under the status and gesture
  // bars; screens pad with SafeArea.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  try {
    await AppFonts.preload();
  } on Object catch (e) {
    // Fonts fall back to the bundled defaults; never block startup.
    developer.log('Font preload failed: $e', name: 'settle_up');
  }
  // bootstrap() reports a failure (newer or unreadable database, full disk)
  // as a StartupFailure, which SettleUpApp shows with Try again.
  runApp(
    AppRoot(
      initial: await bootstrap(),
      load: bootstrap,
      app: const SettleUpApp(),
    ),
  );
}
