import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'bootstrap.dart';
import 'theme/app_theme.dart';
import 'ui/app.dart';
import 'ui/screens/startup/startup_error_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppFonts.configure();
  // Edge to edge: the stone background runs under the status and gesture
  // bars; screens pad with SafeArea. Cosmetic, so a failure only logs.
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );
  } on Object catch (e, st) {
    developer.log(
      'system UI setup failed',
      error: e,
      stackTrace: st,
      name: 'main',
    );
  }
  try {
    await AppFonts.preload();
  } on Object catch (e, st) {
    // The first frame falls back to the platform font; not fatal.
    developer.log(
      'font preload failed',
      error: e,
      stackTrace: st,
      name: 'main',
    );
  }
  runApp(await loadApp());
}

/// Runs [boot] and returns the root widget: the app, or, when startup
/// throws, [StartupErrorApp] whose retry runs [boot] again and swaps the
/// root. Never throws, so main() always reaches runApp.
Future<Widget> loadApp({
  Future<List<Override>> Function() boot = bootstrap,
}) async {
  try {
    final overrides = await boot();
    return ProviderScope(overrides: overrides, child: const SettleUpApp());
  } on Object catch (e, st) {
    developer.log('startup failed', error: e, stackTrace: st, name: 'main');
    return StartupErrorApp(
      failure: classifyStartupError(e),
      onRetry: () async => runApp(await loadApp(boot: boot)),
    );
  }
}
