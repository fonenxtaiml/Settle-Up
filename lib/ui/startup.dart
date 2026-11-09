// What the app shows when it cannot start: a database from a newer app
// version, an unreadable file, a full disk on first launch. The data is
// never touched; the screen explains and offers Try again.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'strings.dart';
import 'widgets/widgets.dart';

/// Why startup failed.
@immutable
final class StartupFailure {
  const StartupFailure(this.error, {this.newerVersion = false});

  /// Classifies [error] from opening the store, settings or ledger.
  factory StartupFailure.from(Object error) => StartupFailure(
    error,
    newerVersion: '$error'.contains('newer than this app'),
  );

  final Object error;

  /// The database was written by a newer Settle Up: update the app.
  final bool newerVersion;
}

/// Set by bootstrap when the real wiring could not be built; null when the
/// app started normally.
final startupFailureProvider = Provider<StartupFailure?>((ref) => null);

/// Runs startup again (set by [AppRoot]).
final startupRetryProvider = Provider<VoidCallback?>((ref) => null);

/// Shows [app] in a ProviderScope with [initial] overrides (built before
/// runApp, so the launch screen stays up until the data is open), or with
/// [load]'s result when [initial] is null and after Try again. [load]
/// should not throw (bootstrap returns a [StartupFailure] override
/// instead); if it does, the failure screen is shown all the same.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    required this.load,
    required this.app,
    this.initial,
  });

  final Future<List<Override>> Function() load;
  final Widget app;
  final List<Override>? initial;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  int _attempt = 0;
  late List<Override>? _overrides = widget.initial;

  @override
  void initState() {
    super.initState();
    if (_overrides == null) _start();
  }

  Future<void> _start() async {
    List<Override> overrides;
    try {
      overrides = await widget.load();
    } on Object catch (e) {
      overrides = [
        startupFailureProvider.overrideWithValue(StartupFailure.from(e)),
      ];
    }
    if (!mounted) return;
    setState(() {
      _attempt++;
      _overrides = overrides;
    });
  }

  void _retry() {
    setState(() => _overrides = null);
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final overrides = _overrides;
    // Only while the data is being opened again.
    if (overrides == null) return const SizedBox.shrink();
    return ProviderScope(
      key: ValueKey(_attempt),
      overrides: [...overrides, startupRetryProvider.overrideWithValue(_retry)],
      child: widget.app,
    );
  }
}

/// The failure screen, in the app's own themes.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.failure, this.onRetry});

  final StartupFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: S.appName,
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: EmptyState(
                  headline: failure.newerVersion
                      ? S.startupNewerTitle
                      : S.startupFailedTitle,
                  body: failure.newerVersion
                      ? S.startupNewerBody
                      : S.startupFailedBody,
                  actionLabel: onRetry == null ? null : S.tryAgain,
                  onAction: onRetry,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
