// FROZEN CONTRACT (docs/SPEC.md section 5.11). Owner: data.
// Interfaces only. Implementations live in lib/data/** (owner: data).
// Dependency rule: lib/data imports lib/core only.
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../core/ops.dart';
import '../core/version_vector.dart';

// ---------------------------------------------------------------- storage --

/// Durable op log + small local tables, one SQLite file (`settle_up.db`).
/// Implementations: SqliteOpStore (package:sqlite3), MemoryOpStore (tests).
abstract interface class OpStore {
  Future<void> open();
  Future<void> close();

  /// INSERT OR IGNORE by op id, all in ONE transaction. Returns the ops that
  /// were actually new, in input order. Also advances the stored contiguous
  /// version vector for each affected (group, device).
  Future<List<Operation>> insertAll(List<Operation> ops);

  Future<List<Operation>> loadAll(); // startup; any order
  Future<VersionVector> versionVector(GroupId groupId); // contiguous prefix

  /// Ops in [groupId] with counter > peer[deviceId] (missing devices = 0),
  /// sorted by (deviceId, counter). Includes ops authored by third devices.
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer);

  /// Highest counter stored for (group, device), 0 if none.
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId);

  /// Local-only removal of every row of a group (used by "leave group").
  Future<void> purgeGroup(GroupId groupId);

  /// What peers are known to hold (pointwise max over all peers).
  Future<VersionVector> peerKnowledge(GroupId groupId);
  Future<void> recordPeerKnowledge(
      DeviceId peer, GroupId groupId, VersionVector vv);

  Future<String?> getKv(String key);
  Future<void> setKv(String key, String? value); // null deletes

  Future<void> addSyncRecord(SyncRecord record);
  Future<List<SyncRecord>> syncRecords({int limit = 50}); // newest first
}

/// 32-byte group secrets. Impl: SecureGroupKeyStore (flutter_secure_storage,
/// key `gk.{groupId}`, base64url value), MemoryGroupKeyStore (tests).
abstract interface class GroupKeyStore {
  Future<Uint8List?> keyFor(GroupId groupId);
  Future<void> put(GroupId groupId, Uint8List key);
  Future<void> remove(GroupId groupId);
  Future<Map<GroupId, Uint8List>> all();
}

// --------------------------------------------------------------- settings --

abstract interface class SettingsRepository {
  /// Created on first launch (deviceId = UUIDv7, deviceName from
  /// device_info_plus, e.g. "Pixel 8"), persisted in kv.
  DeviceIdentity get device;
  Profile? get profile; // null until onboarding is done
  AppSettings get settings;

  Stream<Profile?> watchProfile(); // emits current value first
  Stream<AppSettings> watchSettings(); // emits current value first
  Stream<DeviceIdentity> watchDevice(); // emits current value first

  /// First call creates personId (UUIDv7) when [displayName] is set.
  Future<Profile> completeOnboarding({
    required String displayName,
    required String homeCurrency,
  });
  Future<void> updateProfile(Profile profile); // personId must not change
  Future<void> updateSettings(AppSettings settings);
  Future<void> setDeviceName(String name);
}

// ----------------------------------------------------------------- ledger --

@immutable
final class LedgerSnapshot {
  const LedgerSnapshot({
    required this.state,
    required this.ops,
    required this.pendingJoins,
    required this.unsharedOpIds,
    required this.unsharedCounts,
    required this.localDeviceId,
    this.groupsWithoutKey = const {},
  });

  static LedgerSnapshot empty(DeviceId localDeviceId) => LedgerSnapshot(
        state: LedgerState.empty,
        ops: const [],
        pendingJoins: const {},
        unsharedOpIds: const {},
        unsharedCounts: const {},
        localDeviceId: localDeviceId,
      );

  final LedgerState state;

  /// Every stored op, ascending by HLC. Unmodifiable. Used for activity
  /// and history (ActivityBuilder).
  final List<Operation> ops;

  /// Joined by invite but no group `create` op received yet: id -> name hint.
  final Map<GroupId, String> pendingJoins;

  /// Local ops not yet acknowledged by any peer (OpStore.peerKnowledge).
  final Set<OpId> unsharedOpIds;
  final Map<GroupId, int> unsharedCounts;
  final DeviceId localDeviceId;

  /// Visible groups this phone holds no key for (the keystore lost it):
  /// they still work here but cannot sync until an invite is scanned again.
  final Set<GroupId> groupsWithoutKey;

  int get totalUnshared => unsharedCounts.values.fold(0, (a, b) => a + b);

  /// Entity ids touched by an unshared op (for the "not yet shared" dot).
  /// Computed once per snapshot (the snapshot never changes): screens ask
  /// for it per row, and a scan of every op per row is O(rows x ops).
  Set<String> get unsharedEntityIds =>
      _unsharedEntityIds[this] ??= Set.unmodifiable(<String>{
        if (unsharedOpIds.isNotEmpty)
          for (final op in ops)
            if (unsharedOpIds.contains(op.id)) op.entityId,
      });

  static final _unsharedEntityIds = Expando<Set<String>>('unsharedEntityIds');
}

@immutable
final class NewGroup {
  const NewGroup({
    required this.name,
    required this.type,
    required this.currency,
    this.emoji,
    this.simplifyDebts,
    this.newMemberNames = const [],
    this.existingPeople = const [],
  });

  final String name;
  final GroupType type; // never GroupType.direct (use directGroupWith)
  final String currency;
  final String? emoji;
  final bool? simplifyDebts; // null = AppSettings.simplifyByDefault
  final List<String> newMemberNames; // placeholders with fresh personIds
  final List<({PersonId personId, String displayName})> existingPeople;
}

/// Only non-null fields are written (one `update` op).
@immutable
final class GroupPatch {
  const GroupPatch({
    this.name,
    this.type,
    this.currency,
    this.emoji,
    this.simplifyDebts,
    this.archived,
  });

  final String? name;
  final GroupType? type;
  final String? currency;
  final String? emoji;
  final bool? simplifyDebts;
  final bool? archived;
}

@immutable
final class ExpenseDraft {
  const ExpenseDraft({
    required this.groupId,
    required this.description,
    required this.total,
    required this.currency,
    required this.paidBy,
    required this.owedBy,
    required this.category,
    required this.date,
    this.notes = '',
  });

  final GroupId groupId;
  final String description; // trimmed, non-empty
  final int total; // minor units, 1..Money.maxMinor
  final String currency;
  final SplitSpec paidBy;
  final SplitSpec owedBy;
  final String category;
  final DateTime date;
  final String notes;
}

@immutable
final class PaymentDraft {
  const PaymentDraft({
    required this.groupId,
    required this.from,
    required this.to,
    required this.amount,
    required this.currency,
    required this.method,
    required this.date,
    this.notes = '',
  });

  final GroupId groupId;
  final MemberId from; // who paid
  final MemberId to; // who received
  final int amount; // > 0
  final String currency;
  final PaymentMethod method;
  final DateTime date;
  final String notes;
}

enum LedgerErrorCode {
  notOnboarded,
  groupNotFound,
  memberNotFound,
  expenseNotFound,
  invalidInput,
  invalidSplit,

  /// The phone could not save (storage full, I/O error, keystore error).
  /// Nothing was written; the command can be tried again.
  storageFailed,
}

/// Why an [LedgerErrorCode.invalidInput] was refused, when the UI can say
/// something more useful than "check the fields".
enum LedgerInputIssue {
  /// SPEC 5.16: a group holds at most 50 active members.
  groupFull,

  /// A name, description or note over its SPEC 5.16 length.
  tooLong,
}

final class LedgerException implements Exception {
  const LedgerException(this.code, [this.message = '', this.issue]);
  final LedgerErrorCode code;
  final String message;
  final LedgerInputIssue? issue;
  @override
  String toString() => 'LedgerException(${code.name}: $message)';
}

/// What the UI uses. Every command: validate -> build op(s) with the HLC
/// clock and next counter -> OpStore.insertAll -> reducer.apply -> emit a
/// new snapshot. Throws [LedgerException] (wrapping SplitException as
/// invalidSplit). Commands are serialized (one at a time).
abstract interface class LedgerRepository {
  LedgerSnapshot get current;

  /// Emits [current] immediately, then after every local or remote change.
  Stream<LedgerSnapshot> watch();

  /// Creates group + key (GroupKeyStore) + my member (claimed by this
  /// device) + other members.
  Future<GroupId> createGroup(NewGroup draft);
  Future<void> updateGroup(GroupId groupId, GroupPatch patch);
  Future<void> deleteGroup(GroupId groupId); // tombstone, syncs to everyone

  Future<MemberId> addMember(GroupId groupId,
      {required String displayName, PersonId? personId});
  Future<void> renameMember(GroupId groupId, MemberId memberId, String name);
  Future<void> removeMember(GroupId groupId, MemberId memberId);
  Future<void> mergeMembers(GroupId groupId,
      {required MemberId from, required MemberId into});

  /// "This is me": sets the member's personId to my Profile.personId and
  /// deviceId to this device.
  Future<void> claimMember(GroupId groupId, MemberId memberId);

  /// Finds or creates the direct (1:1) group between me and [personId].
  Future<GroupId> directGroupWith({
    required PersonId personId,
    required String displayName,
    required String currency,
  });

  Future<ExpenseId> addExpense(ExpenseDraft draft);

  /// Writes only fields that differ; money is written as one block.
  Future<void> updateExpense(ExpenseId expenseId, ExpenseDraft draft);
  Future<void> deleteExpense(ExpenseId expenseId);
  Future<void> restoreExpense(ExpenseId expenseId);

  Future<ExpenseId> recordPayment(PaymentDraft draft);
  Future<void> updatePayment(ExpenseId expenseId, PaymentDraft draft);
}

/// What the sync engine uses. Implemented by the same Ledger object.
abstract interface class SyncStore {
  DeviceId get localDeviceId;
  String get localDeviceName;

  /// Groups we hold a key for (pending joins included) -> key.
  Future<Map<GroupId, Uint8List>> groupKeys();

  Future<VersionVector> versionVector(GroupId groupId);
  Future<List<Operation>> opsMissingFor(GroupId groupId, VersionVector peer);

  /// Validates (op.groupId == groupId, key held, parseable, counter >= 1,
  /// hlc.deviceId == deviceId), persists in one transaction, advances the
  /// HLC with the batch max, applies to the reducer, emits a snapshot.
  /// Returns the newly stored ops. Throws FormatException on a bad op
  /// (the whole batch is rejected).
  Future<List<Operation>> applyRemote(GroupId groupId, List<Operation> ops);

  Future<void> recordPeerKnowledge(
      DeviceId peer, GroupId groupId, VersionVector vv);

  /// Every op created locally, as it is committed (for live push).
  Stream<Operation> get localOps;

  /// Stores the key and a pending-join name hint. Idempotent. Returns
  /// false if the group was already known.
  Future<bool> registerJoinedGroup(
      GroupId groupId, Uint8List key, String nameHint);

  Future<void> addSyncRecord(SyncRecord record);
  Stream<List<SyncRecord>> watchSyncRecords(); // newest first, emits first
}
