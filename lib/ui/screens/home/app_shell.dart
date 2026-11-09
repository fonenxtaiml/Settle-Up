// The three-tab shell: Home, Activity, Sync, with the pending-changes badge
// on Sync.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';
import '../../widgets/widgets.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(
      ledgerProvider.select((s) => s.value?.totalUnshared ?? 0),
    );
    return Scaffold(
      body: shell,
      bottomNavigationBar: AppNavigationBar(
        selectedIndex: shell.currentIndex,
        pendingCount: pending,
        onDestinationSelected: (i) =>
            shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}
