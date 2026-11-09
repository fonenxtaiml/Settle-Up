// Startup that cannot open the data (a database from a newer app version,
// an unreadable file, a full disk on first launch) ends on the startup error
// screen with Try again. The data is never touched.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'screens/startup/startup_error_screen.dart';

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
    } on Object catch (_) {
      overrides = [
        startupFailureProvider.overrideWithValue(StartupFailure.other),
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
