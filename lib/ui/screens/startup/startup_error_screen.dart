// Shown instead of the app when startup fails (the data folder is missing,
// the database can't be opened or was written by a newer version). It needs
// no providers: nothing from bootstrap is available here. The data file is
// never touched, so a retry or an app update can still open it.
import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../strings.dart';
import '../../widgets/tether.dart';

/// What went wrong at startup, as far as the user can act on it. The
/// composition root maps the exception (bootstrap.classifyStartupError).
enum StartupFailure {
  /// No data folder (path_provider or the file system failed).
  storage,

  /// The database file exists but can't be opened or read.
  database,

  /// The database was written by a newer version of the app.
  tooNew,

  /// Anything else.
  other,
}

String startupFailureMessage(StartupFailure f) => switch (f) {
  StartupFailure.storage => S.startupStorage,
  StartupFailure.database => S.startupDatabase,
  StartupFailure.tooNew => S.startupTooNew,
  StartupFailure.other => S.startupGeneric,
};

/// A minimal app around [StartupErrorScreen], themed like Settle Up.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.failure, this.onRetry});

  final StartupFailure failure;

  /// Runs startup again; null hides the button.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: S.appName,
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: StartupErrorScreen(failure: failure, onRetry: onRetry),
  );
}

class StartupErrorScreen extends StatefulWidget {
  const StartupErrorScreen({super.key, required this.failure, this.onRetry});

  final StartupFailure failure;
  final Future<void> Function()? onRetry;

  @override
  State<StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<StartupErrorScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry!();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.gutter,
                  vertical: Space.xl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: CustomPaint(
                        size: const Size(112, 24),
                        painter: TetherPainter(
                          from: TetherPoint.ring,
                          to: TetherPoint.ring,
                          line: TetherLine.slack,
                          color: scheme.outline,
                          strokeWidth: 2,
                          pointRadius: 9,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.xl),
                    Semantics(
                      header: true,
                      child: Text(
                        S.startupTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      startupFailureMessage(widget.failure),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      S.startupKept,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (widget.onRetry != null) ...[
                      const SizedBox(height: Space.xl),
                      FilledButton(
                        onPressed: _retrying ? null : _retry,
                        child: const Text(S.startupRetry),
                      ),
                    ],
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
