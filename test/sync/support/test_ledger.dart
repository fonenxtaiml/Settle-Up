// In-memory SyncStore for sync tests, built on the real core reducer and
// following the OpStore / SyncStore contract (SPEC 5.11, 7.1, 7.4):
// insert-or-ignore by op id, contiguous version vectors with gaps, fork
// rejection, third-party ops in missingFor, HLC receive per batch.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';

/// 2026-11-09T00:00:00Z
const int kBaseMs = 1794182400000;

/// Device ids with distinct 8-char prefixes.
String deviceIdOf(String letter) =>
    '${letter * 8}-0000-7000-8000-000000000001';

String groupIdOf(int n) =>
    '00000000-0000-7000-9000-${n.toRadixString(16).padLeft(12, '0')}';

Uint8List groupKeyOf(int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
}

base class TestLedger implements SyncStore {
  TestLedger(
    this.localDeviceId, {
    this.localDeviceName = 'Phone',
    int Function()? nowMillis,
  }) {
    clock = HlcClock(
      deviceId: localDeviceId,
      nowMillis: nowMillis ?? () => kBaseMs + _tick++,
    );
  }

  @override
  final DeviceId localDeviceId;
  @override
  final String localDeviceName;
  late final HlcClock clock;
  int _tick = 0;
  int _opSeq = 0;
  int _entitySeq = 0;

  final Map<GroupId, Uint8List> _keys = {};
  final Map<GroupId, String> pendingJoins = {};
  // group -> device -> counter -> op
  final Map<GroupId, Map<DeviceId, Map<int, Operation>>> _ops = {};
  final Set<OpId> _ids = {};
  final Map<GroupId, Map<DeviceId, int>> _vv = {};
  final Map<(DeviceId, GroupId), VersionVector> peerKnowledge = {};
  final LedgerReducer reducer = LedgerReducer();
  final StreamController<Operation> _local = StreamController.broadcast();
  final List<SyncRecord> records = [];
  final StreamController<List<SyncRecord>> _records =
      StreamController.broadcast();

  /// Every batch passed to [applyRemote] (for duplicate checks).
  int applyRemoteCalls = 0;
  int duplicatesIgnored = 0;

  // ------------------------------------------------------------ queries --

  LedgerState get state => reducer.state;
  Map<String, Object?> get canonical => state.toCanonicalJson();

  List<Operation> opsOf(GroupId g) => [
        for (final byDevice in (_ops[g] ?? const {}).values) ...byDevice.values,
      ];

  int opCount(GroupId g) => opsOf(g).length;

  // ----------------------------------------------------------- SyncStore --

  @override
  Future<Map<GroupId, Uint8List>> groupKeys() async => Map.of(_keys);

  @override
  Future<VersionVector> versionVector(GroupId groupId) async =>
      VersionVector(_vv[groupId] ?? const {});

  @override
  Future<List<Operation>> opsMissingFor(
    GroupId groupId,
    VersionVector peer,
  ) async {
    final out = [
      for (final op in opsOf(groupId))
        if (op.counter > peer[op.deviceId]) op,
    ];
    out.sort((a, b) {
      final c = a.deviceId.compareTo(b.deviceId);
      return c != 0 ? c : a.counter.compareTo(b.counter);
    });
    return out;
  }

  @override
  Future<List<Operation>> applyRemote(
    GroupId groupId,
    List<Operation> ops,
  ) async {
    applyRemoteCalls++;
    if (!_keys.containsKey(groupId)) {
      throw FormatException('No key for $groupId');
    }
    for (final op in ops) {
      if (op.groupId != groupId ||
          op.counter < 1 ||
          op.hlc.deviceId != op.deviceId) {
        throw FormatException('Bad op ${op.id}');
      }
    }
    final added = _insert(ops);
    if (added.isNotEmpty) {
      var max = added.first.hlc;
      for (final op in added) {
        if (op.hlc > max) max = op.hlc;
      }
      clock.receive(max);
      for (final op in added) {
        reducer.apply(op);
      }
    }
    return added;
  }

  List<Operation> _insert(List<Operation> ops) {
    final added = <Operation>[];
    for (final op in ops) {
      if (_ids.contains(op.id)) {
        duplicatesIgnored++;
        continue;
      }
      final byCounter =
          (_ops[op.groupId] ??= {})[op.deviceId] ??= <int, Operation>{};
      if (byCounter.containsKey(op.counter)) {
        duplicatesIgnored++; // fork: keep the first
        continue;
      }
      byCounter[op.counter] = op;
      _ids.add(op.id);
      added.add(op);
      final vv = _vv[op.groupId] ??= {};
      var n = vv[op.deviceId] ?? 0;
      while (byCounter.containsKey(n + 1)) {
        n++;
      }
      vv[op.deviceId] = n;
    }
    return added;
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) async {
    final key = (peer, groupId);
    peerKnowledge[key] = (peerKnowledge[key] ?? VersionVector.empty).merge(vv);
  }

  @override
  Stream<Operation> get localOps => _local.stream;

  /// Whether a session still listens to [localOps] (leak checks).
  bool get hasLocalOpsListener => _local.hasListener;

  @override
  Future<bool> registerJoinedGroup(
    GroupId groupId,
    Uint8List key,
    String nameHint,
  ) async {
    if (_keys.containsKey(groupId)) return false;
    _keys[groupId] = Uint8List.fromList(key);
    pendingJoins[groupId] = nameHint;
    return true;
  }

  @override
  Future<void> addSyncRecord(SyncRecord record) async {
    records.insert(0, record);
    _records.add(List.unmodifiable(records));
  }

  @override
  Stream<List<SyncRecord>> watchSyncRecords() => Stream.multi((c) {
        c.add(List.unmodifiable(records));
        final sub = _records.stream.listen(c.add);
        c.onCancel = sub.cancel;
      });

  // ------------------------------------------------------- local writes --

  Future<Operation> author(
    GroupId g,
    EntityType type,
    String entityId,
    OpKind kind,
    Map<String, Object?> payload,
  ) async {
    final hlc = clock.tick();
    final counter = (_vv[g]?[localDeviceId] ?? 0) + 1;
    final op = Operation(
      id: '$localDeviceId/${++_opSeq}',
      groupId: g,
      deviceId: localDeviceId,
      counter: counter,
      hlc: hlc,
      entityType: type,
      entityId: entityId,
      kind: kind,
      payload: payload,
    );
    _insert([op]);
    reducer.apply(op);
    _local.add(op);
    return op;
  }

  String _newId(String kind) => '$localDeviceId/$kind/${++_entitySeq}';

  /// Creates the group (holding [key]) and returns its id.
  Future<GroupId> authorGroup(
    GroupId g,
    Uint8List key, {
    String name = 'Goa trip',
  }) async {
    _keys[g] = Uint8List.fromList(key);
    await author(g, EntityType.group, g, OpKind.create, {
      GroupFields.name: name,
      GroupFields.type: GroupType.trip.name,
      GroupFields.currency: 'INR',
      GroupFields.simplifyDebts: true,
      GroupFields.createdAt: clock.last.millis,
    });
    return g;
  }

  Future<MemberId> authorMember(GroupId g, String name) async {
    final m = _newId('m');
    await author(g, EntityType.member, m, OpKind.create, {
      MemberFields.displayName: name,
      MemberFields.personId: 'person-$m',
      MemberFields.createdAt: clock.last.millis,
    });
    return m;
  }

  Future<ExpenseId> authorExpense(
    GroupId g, {
    required MemberId payer,
    required List<MemberId> owers,
    int total = 6000,
    String description = 'Dinner',
  }) async {
    final e = _newId('e');
    final money = SplitCalculator.buildMoneyBlock(
      total: total,
      currency: 'INR',
      paidBy: SplitSpec.single(payer, total),
      owedBy: SplitSpec.equal(owers),
    );
    await author(g, EntityType.expense, e, OpKind.create, {
      ExpenseFields.kind: ExpenseKind.expense.name,
      ExpenseFields.description: description,
      ExpenseFields.category: 'food.dining',
      ExpenseFields.date: clock.last.millis,
      ExpenseFields.money: money.toJson(),
      ExpenseFields.createdBy: payer,
      ExpenseFields.createdAt: clock.last.millis,
      ExpenseFields.notes: '',
    });
    return e;
  }

  Future<void> rename(GroupId g, ExpenseId e, String description) =>
      author(g, EntityType.expense, e, OpKind.update, {
        ExpenseFields.description: description,
      });

  Future<void> dispose() async {
    await _local.close();
    await _records.close();
  }
}

/// A group with two members and [expenses] expenses authored on [owner].
Future<({GroupId g, MemberId a, MemberId b})> seedGroup(
  TestLedger owner, {
  int group = 1,
  int expenses = 3,
}) async {
  final g = await owner.authorGroup(groupIdOf(group), groupKeyOf(group));
  final a = await owner.authorMember(g, 'Alex');
  final b = await owner.authorMember(g, 'Priya');
  for (var i = 0; i < expenses; i++) {
    await owner.authorExpense(g,
        payer: a, owers: [a, b], total: 1000 + i, description: 'Item $i');
  }
  return (g: g, a: a, b: b);
}
