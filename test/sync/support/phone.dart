// A simulated phone for sync tests: the real data layer
// (Ledger over MemoryOpStore, KvSettingsRepository, MemoryGroupKeyStore),
// as SPEC 11.3 requires, plus a thin SyncStore spy for the counts the
// tests assert on (batches applied, duplicates, localOps listeners).
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';

/// 2026-11-09T00:00:00Z
const int kBaseMs = 1794182400000;

/// Device ids with distinct 8-char prefixes.
String deviceIdOf(String letter) => '${letter * 8}-0000-7000-8000-000000000001';

/// A fixed group id (for handshake-only tests; ledgers make their own).
String groupIdOf(int n) =>
    '00000000-0000-7000-9000-${n.toRadixString(16).padLeft(12, '0')}';

/// A deterministic 32-byte group key.
Uint8List groupKeyOf(int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
}

/// Ids unique per phone: the first one is the device id.
final class PhoneIds implements IdGenerator {
  PhoneIds(this.letter);
  final String letter;
  int _next = 0;

  @override
  String newId() {
    final n = _next++;
    if (n == 0) return deviceIdOf(letter);
    return '${letter * 8}-0000-7000-9000-${n.toRadixString(16).padLeft(12, '0')}';
  }
}

/// Forwards to the real store and counts what the session does with it.
final class SpyStore implements SyncStore {
  SpyStore(this.inner);

  final SyncStore inner;

  /// Batches passed to [applyRemote].
  int applyRemoteCalls = 0;

  /// Ops passed to [applyRemote] that were already stored.
  int duplicatesIgnored = 0;

  /// When set, replaces [applyRemote] (e.g. a store that rejects).
  Future<List<Operation>> Function(GroupId, List<Operation>)? onApplyRemote;

  StreamSubscription<Operation>? _innerLocal;
  late final StreamController<Operation> _local = StreamController.broadcast(
    onListen: () => _innerLocal = inner.localOps.listen(_local.add),
    onCancel: () {
      unawaited(_innerLocal?.cancel());
      _innerLocal = null;
    },
  );

  /// Whether a session still listens to [localOps] (leak checks).
  bool get hasLocalOpsListener => _local.hasListener;

  @override
  DeviceId get localDeviceId => inner.localDeviceId;
  @override
  String get localDeviceName => inner.localDeviceName;
  @override
  Stream<String> watchLocalDeviceName() => inner.watchLocalDeviceName();
  @override
  Future<Map<GroupId, Uint8List>> groupKeys() => inner.groupKeys();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> opsMissingFor(GroupId groupId, VersionVector peer) =>
      inner.opsMissingFor(groupId, peer);

  @override
  Future<List<Operation>> applyRemote(
    GroupId groupId,
    List<Operation> ops,
  ) async {
    applyRemoteCalls++;
    final override = onApplyRemote;
    if (override != null) return override(groupId, ops);
    final added = await inner.applyRemote(groupId, ops);
    duplicatesIgnored += ops.length - added.length;
    return added;
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Stream<Operation> get localOps => _local.stream;
  @override
  Future<bool> registerJoinedGroup(
    GroupId groupId,
    Uint8List key,
    String nameHint,
  ) => inner.registerJoinedGroup(groupId, key, nameHint);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Stream<List<SyncRecord>> watchSyncRecords() => inner.watchSyncRecords();
}

/// A group seeded on its owner: the owner's member [a] and [b] ("Priya").
typedef Seed = ({GroupId g, MemberId a, MemberId b});

final class TestPhone {
  TestPhone._(this.letter, this.opStore, this.settings, this.ledger)
    : store = SpyStore(ledger);

  /// A phone with device id [deviceIdOf] ([letter]), onboarded as [name].
  static Future<TestPhone> create(
    String letter, {
    String? deviceName,
    String name = 'Alex',
  }) async {
    final opStore = MemoryOpStore();
    await opStore.open();
    final ids = PhoneIds(letter);
    final settings = await KvSettingsRepository.open(
      opStore,
      defaultDeviceName: deviceName ?? 'Phone ${letter.toUpperCase()}',
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: name, homeCurrency: 'INR');
    final ledger = await Ledger.open(
      store: opStore,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
    );
    return TestPhone._(letter, opStore, settings, ledger);
  }

  final String letter;
  final MemoryOpStore opStore;
  final KvSettingsRepository settings;
  final Ledger ledger;

  /// What sessions are given (forwards to [ledger]).
  final SpyStore store;

  DeviceId get deviceId => ledger.localDeviceId;
  String get deviceName => ledger.localDeviceName;
  LedgerSnapshot get snapshot => ledger.current;
  LedgerState get state => ledger.current.state;
  Map<String, Object?> get canonical => state.toCanonicalJson();

  List<Operation> opsOf(GroupId g) => [
    for (final op in ledger.current.ops)
      if (op.groupId == g) op,
  ];

  int opCount(GroupId g) => opsOf(g).length;

  int get duplicatesIgnored => store.duplicatesIgnored;
  int get applyRemoteCalls => store.applyRemoteCalls;
  bool get hasLocalOpsListener => store.hasLocalOpsListener;

  /// Merged knowledge of every peer about [g] (what they told us they hold).
  Future<VersionVector> peerKnowledge(GroupId g) => opStore.peerKnowledge(g);

  Future<List<SyncRecord>> records() => ledger.watchSyncRecords().first;

  Future<Uint8List> keyOf(GroupId g) async => (await ledger.groupKeys())[g]!;

  /// Creates a group with the owner and "Priya", then [expenses] expenses
  /// (3 + [expenses] ops).
  Future<Seed> seedGroup({int expenses = 3, String name = 'Goa trip'}) async {
    final g = await ledger.createGroup(
      NewGroup(
        name: name,
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: const ['Priya'],
      ),
    );
    final members = state.groups[g]!.members.values;
    final b = members.firstWhere((m) => m.displayName == 'Priya').id;
    final a = members.firstWhere((m) => m.id != b).id;
    for (var i = 0; i < expenses; i++) {
      await addExpense(
        g,
        payer: a,
        owers: [a, b],
        total: 1000 + i,
        description: 'Item $i',
      );
    }
    return (g: g, a: a, b: b);
  }

  /// Stores [owner]'s key for [g] (like accepting an invite).
  Future<void> join(TestPhone owner, GroupId g) async {
    await ledger.registerJoinedGroup(g, await owner.keyOf(g), 'Goa trip');
  }

  Future<ExpenseId> addExpense(
    GroupId g, {
    required MemberId payer,
    required List<MemberId> owers,
    int total = 6000,
    String description = 'Dinner',
  }) => ledger.addExpense(
    ExpenseDraft(
      groupId: g,
      description: description,
      total: total,
      currency: 'INR',
      paidBy: SplitSpec.single(payer, total),
      owedBy: SplitSpec.equal(owers),
      category: 'food.dining',
      date: utcFromMillis(kBaseMs),
    ),
  );

  /// Writes [count] expenses alternating payers.
  Future<void> addExpenses(Seed s, int count, {int base = 100}) async {
    for (var i = 0; i < count; i++) {
      await addExpense(
        s.g,
        payer: i.isEven ? s.a : s.b,
        owers: [s.a, s.b],
        total: base + i,
        description: 'E$i',
      );
    }
  }

  Future<void> rename(GroupId g, ExpenseId e, String description) {
    final x = state.groups[g]!.expenses[e]!;
    return ledger.updateExpense(
      e,
      ExpenseDraft(
        groupId: g,
        description: description,
        total: x.money.total,
        currency: x.money.currency,
        paidBy: x.money.paidBy,
        owedBy: x.money.owedBy,
        category: x.category,
        date: x.date,
        notes: x.notes,
      ),
    );
  }

  Future<void> close() => ledger.close();
}
