// FROZEN CONTRACT (docs/SPEC.md section 5.14). Owner: ui.
// Riverpod 3, no codegen. Root providers are overridden in lib/bootstrap.dart
// (real app) or in tests (fakes). Screens may add private providers in their
// own files but must not change these.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/activity.dart';
import '../core/balances.dart';
import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../data/repositories.dart';
import '../sync/sync_engine.dart';

// ------------------------------------------------------------------ roots --

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

final ledgerRepositoryProvider = Provider<LedgerRepository>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

// ---------------------------------------------------------------- streams --

final profileProvider = StreamProvider<Profile?>(
  (ref) => ref.watch(settingsRepositoryProvider).watchProfile(),
);

final appSettingsProvider = StreamProvider<AppSettings>(
  (ref) => ref.watch(settingsRepositoryProvider).watchSettings(),
);

final deviceIdentityProvider = StreamProvider<DeviceIdentity>(
  (ref) => ref.watch(settingsRepositoryProvider).watchDevice(),
);

final ledgerProvider = StreamProvider<LedgerSnapshot>(
  (ref) => ref.watch(ledgerRepositoryProvider).watch(),
);

final syncStatusProvider = StreamProvider<SyncStatus>(
  (ref) => ref.watch(syncEngineProvider).watchStatus(),
);

final nearbyPeersProvider = StreamProvider<List<NearbyPeer>>(
  (ref) => ref.watch(syncEngineProvider).watchNearby(),
);

final syncHistoryProvider = StreamProvider<List<SyncRecord>>(
  (ref) => ref.watch(syncEngineProvider).watchHistory(),
);

// ---------------------------------------------------------------- derived --
// Pure functions of (snapshot, me). AsyncLoading until both are available.

AsyncValue<R> _withMe<R>(
  Ref ref,
  R Function(LedgerSnapshot snap, PersonId me) build,
) {
  final snap = ref.watch(ledgerProvider);
  final profile = ref.watch(profileProvider);
  if (snap case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (profile case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  final s = snap.value;
  final p = profile.value;
  if (s == null || p == null) return const AsyncLoading();
  return AsyncData(build(s, p.personId));
}

final groupSummariesProvider = Provider<AsyncValue<List<GroupBalanceSummary>>>(
  (ref) => _withMe(ref, (s, me) => Summaries.groups(s.state, me)),
);

final peopleBalancesProvider = Provider<AsyncValue<List<PersonBalance>>>(
  (ref) => _withMe(ref, (s, me) => Summaries.people(s.state, me)),
);

final overallBalanceProvider = Provider<AsyncValue<OverallBalance>>(
  (ref) => _withMe(ref, (s, me) => Summaries.overall(s.state, me)),
);

final groupProvider = Provider.family<AsyncValue<GroupState?>, GroupId>(
  (ref, groupId) =>
      ref.watch(ledgerProvider).whenData((s) => s.state.groups[groupId]),
);

final groupTransfersProvider =
    Provider.family<AsyncValue<List<Transfer>>, GroupId>(
      (ref, groupId) => ref.watch(ledgerProvider).whenData((s) {
        final g = s.state.groups[groupId];
        return g == null
            ? const <Transfer>[]
            : BalanceCalculator.suggestedTransfers(g);
      }),
    );

final groupNetsProvider = Provider.family<AsyncValue<NetsByCurrency>, GroupId>(
  (ref, groupId) => ref.watch(ledgerProvider).whenData((s) {
    final g = s.state.groups[groupId];
    return g == null
        ? const <String, Map<MemberId, int>>{}
        : BalanceCalculator.groupNets(g);
  }),
);

/// null = all groups.
final activityProvider =
    Provider.family<AsyncValue<List<ActivityEntry>>, GroupId?>(
      (ref, groupId) => ref
          .watch(ledgerProvider)
          .whenData(
            (s) => ActivityBuilder.build(
              ops: s.ops,
              state: s.state,
              localDeviceId: s.localDeviceId,
              unsharedOpIds: s.unsharedOpIds,
              groupId: groupId,
            ),
          ),
    );

/// History of one expense, keyed by (group, expense): entity ids are scoped
/// by group (SPEC 7.2).
final expenseHistoryProvider =
    Provider.family<AsyncValue<List<ActivityEntry>>, (GroupId, ExpenseId)>(
      (ref, key) => ref
          .watch(ledgerProvider)
          .whenData(
            (s) => ActivityBuilder.historyOf(
              ops: s.ops,
              state: s.state,
              localDeviceId: s.localDeviceId,
              unsharedOpIds: s.unsharedOpIds,
              groupId: key.$1,
              entityId: key.$2,
            ),
          ),
    );
