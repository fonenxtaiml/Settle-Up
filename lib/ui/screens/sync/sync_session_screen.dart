// A running sync, step by step; then what arrived, or why it stopped.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../sync/sync_engine.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

class SyncSessionScreen extends ConsumerStatefulWidget {
  const SyncSessionScreen({super.key});

  @override
  ConsumerState<SyncSessionScreen> createState() => _SyncSessionScreenState();
}

class _SyncSessionScreenState extends ConsumerState<SyncSessionScreen> {
  bool _celebrated = false;

  void _done() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.sync);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session =
        ref.watch(syncStatusProvider).value?.session ?? const SessionIdle();
    if (session is SessionCompleted && !_celebrated) {
      _celebrated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Haptics.medium(context);
      });
    }
    return Scaffold(
      appBar: screenAppBar(
        leading: BackArrow(close: true, onPressed: _done),
        title: const Text(S.syncTitle),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: switch (session) {
            SessionActive() => FilledButton.tonal(
              onPressed: () => ref.read(syncEngineProvider).cancel(),
              style: KitButtonStyles.block,
              child: const Text(S.cancel),
            ),
            SessionFailed() => FilledButton(
              onPressed: () => context.go(Routes.sync),
              style: KitButtonStyles.block,
              child: const Text(S.tryAgain),
            ),
            _ => FilledButton(
              onPressed: _done,
              style: KitButtonStyles.block,
              child: const Text(S.done),
            ),
          },
        ),
      ),
      body: SessionView(session: session),
    );
  }
}

/// The body for each [SessionStatus]; also used by tests.
class SessionView extends ConsumerWidget {
  const SessionView({super.key, required this.session});

  final SessionStatus session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final body = theme.textTheme.bodyLarge!.copyWith(color: ink2);
    final groups = {
      for (final g
          in ref.watch(ledgerProvider).value?.state.visibleGroups ??
              const <Never>[])
        g.groupId: g.group!.name,
    };
    final children = switch (session) {
      SessionIdle() => [
        Text(S.sessionIdle, style: theme.textTheme.headlineSmall),
        const SizedBox(height: Space.sm),
        Text(S.sessionIdleBody, style: body),
      ],
      SessionActive(:final progress) => [
        Text(
          S.syncingWith(progress.peerName),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: Space.md),
        const SyncTether(active: true),
        const SizedBox(height: Space.lg),
        ..._steps(context, progress),
        const SizedBox(height: Space.lg),
        // Before the transfer the bar has no fraction to show and sweeps;
        // under "Remove animations" it stays still at the start and the
        // steps above carry the state, as KitSpinner does.
        LinearProgressIndicator(
          value:
              _fraction(progress) ??
              (MediaQuery.disableAnimationsOf(context) ? 0 : null),
        ),
        if (progress.verificationCode != null) ...[
          const SizedBox(height: Space.lg),
          Text(
            S.verification(
              progress.peerName,
              '${progress.verificationCode!.substring(0, 3)} '
              '${progress.verificationCode!.substring(3)}',
            ),
            style: theme.textTheme.titleMedium,
          ),
        ],
        const SizedBox(height: Space.md),
        Text(
          S.keepClose,
          style: theme.textTheme.bodySmall!.copyWith(color: ink2),
        ),
      ],
      SessionCompleted(:final summary) => [
        Text(
          S.syncedWithTitle(summary.peerName),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: Space.md),
        const SyncTether(connected: true),
        const SizedBox(height: Space.lg),
        Text(S.sentAndGot(summary.sentOps, summary.receivedOps), style: body),
        for (final e in summary.receivedByGroup.entries)
          if (groups[e.key] != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(
                '${groups[e.key]}: ${S.changes(e.value)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
      ],
      SessionFailed(:final failure, :final partial) => [
        Text(S.syncStopped, style: theme.textTheme.headlineSmall),
        const SizedBox(height: Space.md),
        Text(syncFailureMessage(failure), style: body),
        const SizedBox(height: Space.sm),
        Text(
          partial == null || partial.receivedOps == 0
              ? S.nothingLost
              : S.partialArrived(partial.receivedOps),
          style: body,
        ),
      ],
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Space.text,
        Space.sm,
        Space.text,
        Space.xl,
      ),
      children: children,
    );
  }

  static double? _fraction(SyncProgress p) {
    final total = p.toSendOps + p.toReceiveOps;
    if (p.phase.index < SyncPhase.transferring.index) return null;
    if (total == 0) return p.phase == SyncPhase.finishing ? 1 : null;
    return ((p.sentOps + p.receivedOps) / total).clamp(0, 1).toDouble();
  }

  static List<Widget> _steps(BuildContext context, SyncProgress p) {
    final phase = p.phase.index;
    Widget step(String label, {required bool done, required bool current}) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 22,
              child: done
                  ? const Icon(Icons.check_rounded, size: 20)
                  : current
                  ? const Padding(
                      padding: EdgeInsets.all(3),
                      child: KitSpinner(),
                    )
                  : Icon(
                      Icons.circle_outlined,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge!.copyWith(
                  color: done || current
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final transferring = SyncPhase.transferring.index;
    return [
      step(
        phase > 0 ? S.stepConnected : S.stepConnecting,
        done: phase > 0,
        current: phase == 0,
      ),
      step(
        phase > 1 ? S.stepChecked : S.stepChecking,
        done: phase > 1,
        current: phase == 1,
      ),
      step(
        phase > 2 ? S.stepCompared : S.stepComparing,
        done: phase > 2,
        current: phase == 2,
      ),
      step(
        S.stepSending(p.sentOps, p.toSendOps),
        done:
            phase > transferring ||
            (phase == transferring && p.sentOps >= p.toSendOps),
        current: phase == transferring && p.sentOps < p.toSendOps,
      ),
      step(
        S.stepReceiving(p.receivedOps, p.toReceiveOps),
        done: phase > transferring,
        current: phase == transferring,
      ),
    ];
  }
}
