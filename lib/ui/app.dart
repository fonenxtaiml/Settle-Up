// The app shell: MaterialApp.router with the Point to Point themes, the
// theme mode from AppSettings and the vibration switch for haptics.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import 'providers.dart';
import 'router.dart';
import 'strings.dart';
import 'widgets/widgets.dart';

class SettleUpApp extends ConsumerWidget {
  const SettleUpApp({super.key});

  static ThemeMode themeModeOf(AppThemeMode mode) => switch (mode) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: S.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeModeOf(settings.themeMode),
      routerConfig: router,
      builder: (context, child) => HapticsScope(
        enabled: settings.vibration,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
