// The app shell: MaterialApp.router with the Point to Point themes, the
// theme mode from AppSettings and the vibration switch for haptics. The
// theme mode is also handed to Android (API 31+), so the next cold start's
// splash and launch window use the same light or dark stone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import 'format/app_material_localizations.dart';
import 'platform/app_window.dart';
import 'providers.dart';
import 'router.dart';
import 'screens/startup/startup_error_screen.dart';
import 'startup.dart';
import 'strings.dart';
import 'widgets/widgets.dart';

class SettleUpApp extends ConsumerStatefulWidget {
  const SettleUpApp({super.key});

  static ThemeMode themeModeOf(AppThemeMode mode) => switch (mode) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  @override
  ConsumerState<SettleUpApp> createState() => _SettleUpAppState();
}

class _SettleUpAppState extends ConsumerState<SettleUpApp> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Nothing to follow when startup failed: there are no settings.
    if (ref.read(startupFailureProvider) != null) return;
    // Back in the foreground: time passed or the date may have been
    // changed meanwhile, which can set or clear the Settings clock notice
    // (DATA-R31-01).
    _lifecycle = AppLifecycleListener(
      onResume: () =>
          unawaited(ref.read(ledgerRepositoryProvider).recheckClock()),
    );
    ref.listenManual(appSettingsProvider, (_, next) {
      final settings = next.value;
      if (settings != null) {
        unawaited(AppWindow.setNightMode(settings.themeMode));
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure = ref.watch(startupFailureProvider);
    if (failure != null) {
      final retry = ref.watch(startupRetryProvider);
      return StartupErrorApp(
        failure: failure,
        onRetry: retry == null ? null : () async => retry(),
      );
    }
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: S.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: SettleUpApp.themeModeOf(settings.themeMode),
      routerConfig: router,
      // Day-first dates in every Material widget (VISUAL-R11-01).
      localizationsDelegates: const [AppMaterialLocalizations.delegate],
      builder: (context, child) => HapticsScope(
        enabled: settings.vibration,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
