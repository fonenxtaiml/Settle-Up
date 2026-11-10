// In-memory LedgerRepository for development builds and widget tests
// (SPEC 10.2). It writes real ops and folds them with the real core
// reducer, so balances, activity and history behave exactly as with the
// SQLite-backed Ledger; only persistence is missing.
import 'dart:async';

import '../../core/hlc.dart';
import '../../core/ids.dart';
import '../../core/ledger_state.dart';
import '../../core/models.dart';
import '../../core/ops.dart';
import '../../core/split.dart';
import '../../data/repositories.dart';

final class FakeLedgerRepository implements LedgerRepository {
  FakeLedgerRepository({
    required SettingsRepository settings,
    IdGenerator ids = const UuidV7Generator(),
    int Function()? nowMillis,
  }) : _settings = settings,
       _idGen = ids,
       _now = nowMillis ?? _wallClock {
    _snapshot = LedgerSnapshot.empty(settings.device.deviceId);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final SettingsRepository _settings;
  final IdGenerator _idGen;
  final int Function() _now;
  final LedgerReducer _reducer = LedgerReducer();
  final List<Operation> _ops = [];
  final Set<OpId> _unshared = {};
  final Map<GroupId, String> _pendingJoins = {};
  final Map<(GroupId, DeviceId), int> _counters = {};
  final Map<DeviceId, HlcClock> _clocks = {};
  final _changes = StreamController<LedgerSnapshot>.broadcast();
  late LedgerSnapshot _snapshot;

  // Authoring context; seed data writes ops "from" other phones.
  DeviceId? _actingDevice;
  PersonId? _actingPerson;
  int? _actingAt;
  String? _actingName;
  bool _batching = false;

  // ------------------------------------------------------ test recorders --

  final List<NewGroup> createdGroups = [];
  final List<(GroupId, GroupPatch)> groupUpdates = [];
  final List<ExpenseDraft> addedExpenses = [];
  final List<(ExpenseId, ExpenseDraft)> updatedExpenses = [];
  final List<ExpenseId> deletedExpenses = [];
  final List<ExpenseId> restoredExpenses = [];
  final List<PaymentDraft> recordedPayments = [];
  final List<(GroupId, MemberId)> claimedMembers = [];

  /// Forgets the recorded calls (after seeding).
  void clearRecords() {
    createdGroups.clear();
    groupUpdates.clear();
    addedExpenses.clear();
    updatedExpenses.clear();
    deletedExpenses.clear();
    restoredExpenses.clear();
    recordedPayments.clear();
    claimedMembers.clear();
  }

  DeviceId get localDeviceId => _settings.device.deviceId;

  // -------------------------------------------------------------- reading --

  @override
  LedgerSnapshot get current => _snapshot;

  @override
  Stream<LedgerSnapshot> watch() async* {
    yield _snapshot;
    yield* _changes.stream;
  }

  // ------------------------------------------------------- dev utilities --

  /// Runs [body] as if another phone (owned by [person]) wrote it at [at].
  /// Used by seedDemoData; ops written this way are already "shared".
  Future<T> actAs<T>({
    required DeviceId device,
    required PersonId person,
    required DateTime at,
    required Future<T> Function() body,
  }) async {
    final prev = (_actingDevice, _actingPerson, _actingAt);
    _actingDevice = device;
    _actingPerson = person;
    _actingAt = at.millisecondsSinceEpoch;
    try {
      return await body();
    } finally {
      _actingDevice = prev.$1;
      _actingPerson = prev.$2;
      _actingAt = prev.$3;
    }
  }

  /// Runs [body] on this phone at a fixed time (seed data).
  Future<T> actAt<T>(DateTime at, Future<T> Function() body) async {
    final prev = _actingAt;
    _actingAt = at.millisecondsSinceEpoch;
    try {
      return await body();
    } finally {
      _actingAt = prev;
    }
  }

  /// Applies many commands and emits one snapshot at the end.
  Future<void> batch(Future<void> Function() body) async {
    _batching = true;
    try {
      await body();
    } finally {
      _batching = false;
      _emit();
    }
  }

  /// Pretends every local op reached another phone (a finished sync).
  void markAllShared() {
    _unshared.clear();
    _emit();
  }

  /// Leaves only the newest [count] local ops waiting to be shared.
  void keepUnshared(int count) {
    final local = [
      for (final op in _ops)
        if (_unshared.contains(op.id)) op,
    ]..sort((a, b) => a.hlc.compareTo(b.hlc));
    _unshared
      ..clear()
      ..addAll(
        local
            .skip(local.length - count.clamp(0, local.length))
            .map((o) => o.id),
      );
    _emit();
  }

  /// Creates the group behind an invite as the inviter's phone would have
  /// (the fake engine's stand-in for the first sync after joining).
  Future<void> createJoinedGroup({
    required GroupId groupId,
    required String name,
    required String currency,
    required DeviceId inviterDevice,
    required String inviterName,
    List<String> otherMembers = const [],
  }) async {
    final inviter = _idGen.newId();
    await actAs(
      device: inviterDevice,
      person: inviter,
      at: DateTime.fromMillisecondsSinceEpoch(_now()),
      body: () async {
        _actingName = inviterName;
        try {
          _createGroup(
            id: groupId,
            name: name,
            type: GroupType.other,
            currency: currency,
            simplify: true,
          );
          for (final n in otherMembers) {
            _addMemberOp(groupId, _idGen.newId(), n, _idGen.newId());
          }
        } finally {
          _actingName = null;
        }
      },
    );
    _emit();
  }

  /// Registers a group known only by invite (no create op yet).
  void addPendingJoin(GroupId groupId, String nameHint) {
    _pendingJoins[groupId] = nameHint;
    _emit();
  }

  // ----------------------------------------------------------- internals --

  PersonId get _me {
    final p = _actingPerson ?? _settings.profile?.personId;
    if (p == null) {
      throw const LedgerException(LedgerErrorCode.notOnboarded);
    }
    return p;
  }

  DeviceId get _device => _actingDevice ?? localDeviceId;

  int get _nowMs => _actingAt ?? _now();

  HlcClock _clock(DeviceId d) => _clocks.putIfAbsent(
    d,
    () => HlcClock(deviceId: d, nowMillis: () => _nowMs),
  );

  void _write(
    GroupId groupId,
    EntityType type,
    String entityId,
    OpKind kind,
    Map<String, Object?> payload,
  ) {
    final device = _device;
    final key = (groupId, device);
    final counter = (_counters[key] ?? 0) + 1;
    _counters[key] = counter;
    final op = Operation(
      id: _idGen.newId(),
      groupId: groupId,
      deviceId: device,
      counter: counter,
      hlc: _clock(device).tick(),
      entityType: type,
      entityId: entityId,
      kind: kind,
      payload: payload,
    );
    _ops.add(op);
    if (device == localDeviceId) _unshared.add(op.id);
    _reducer.apply(op);
    _pendingJoins.remove(groupId);
  }

  void _emit() {
    final sorted = List<Operation>.of(_ops)
      ..sort((a, b) {
        final c = a.hlc.compareTo(b.hlc);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final counts = <GroupId, int>{};
    for (final op in _ops) {
      if (_unshared.contains(op.id)) {
        counts[op.groupId] = (counts[op.groupId] ?? 0) + 1;
      }
    }
    _snapshot = LedgerSnapshot(
      state: _reducer.state,
      ops: List.unmodifiable(sorted),
      pendingJoins: Map.unmodifiable(_pendingJoins),
      unsharedOpIds: Set.unmodifiable(_unshared),
      unsharedCounts: Map.unmodifiable(counts),
      localDeviceId: localDeviceId,
    );
    if (!_batching) _changes.add(_snapshot);
  }

  GroupState _group(GroupId id) {
    final g = _reducer.state.groups[id];
    if (g == null || g.group == null || g.group!.isDeleted) {
      throw LedgerException(LedgerErrorCode.groupNotFound, id);
    }
    return g;
  }

  Member _member(GroupState g, MemberId id) {
    final m = g.members[id];
    if (m == null) throw LedgerException(LedgerErrorCode.memberNotFound, id);
    return m;
  }

  Expense _expense(ExpenseId id, {GroupId? groupId}) {
    final e = groupId == null
        ? _reducer.state.expense(id)
        : _reducer.state.expenseIn(groupId, id);
    if (e == null) throw LedgerException(LedgerErrorCode.expenseNotFound, id);
    return e;
  }

  String _myName() {
    if (_actingName != null) return _actingName!;
    final p = _settings.profile;
    if (_actingPerson != null || p == null) return 'Me';
    return p.displayName;
  }

  /// Seed helper: the display name used for "my" member when a group is
  /// created while acting as another phone.
  Future<T> actingNamed<T>(String name, Future<T> Function() body) async {
    final prev = _actingName;
    _actingName = name;
    try {
      return await body();
    } finally {
      _actingName = prev;
    }
  }

  void _addMemberOp(
    GroupId groupId,
    MemberId id,
    String name,
    PersonId personId, {
    DeviceId? deviceId,
  }) {
    _write(groupId, EntityType.member, id, OpKind.create, {
      MemberFields.displayName: name,
      MemberFields.personId: personId,
      MemberFields.createdAt: _nowMs,
      MemberFields.deviceId: ?deviceId,
    });
  }

  MemberId? _myMemberIn(GroupState g) {
    final m = g.memberForPerson(_me);
    return m == null ? null : g.resolve(m.id);
  }

  String _cleanName(String name) {
    final t = name.trim();
    if (t.isEmpty) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'name');
    }
    return t;
  }

  // ------------------------------------------------------------- groups --

  @override
  Future<GroupId> createGroup(NewGroup draft) async {
    createdGroups.add(draft);
    final name = _cleanName(draft.name);
    if (draft.type == GroupType.direct) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'direct');
    }
    final id = _createGroup(
      name: name,
      type: draft.type,
      currency: draft.currency,
      emoji: draft.emoji,
      simplify: draft.simplifyDebts ?? _settings.settings.simplifyByDefault,
    );
    for (final n in draft.newMemberNames) {
      if (n.trim().isEmpty) continue;
      _addMemberOp(id, _idGen.newId(), n.trim(), _idGen.newId());
    }
    for (final p in draft.existingPeople) {
      _addMemberOp(id, _idGen.newId(), p.displayName, p.personId);
    }
    _emit();
    return id;
  }

  GroupId _createGroup({
    required String name,
    required GroupType type,
    required String currency,
    required bool simplify,
    String? emoji,
    GroupId? id,
  }) {
    id ??= _idGen.newId();
    _write(id, EntityType.group, id, OpKind.create, {
      GroupFields.name: name,
      GroupFields.type: type.name,
      GroupFields.currency: currency,
      GroupFields.simplifyDebts: simplify,
      GroupFields.createdAt: _nowMs,
      GroupFields.emoji: ?emoji,
    });
    _addMemberOp(id, _idGen.newId(), _myName(), _me, deviceId: _device);
    return id;
  }

  @override
  Future<void> updateGroup(GroupId groupId, GroupPatch patch) async {
    groupUpdates.add((groupId, patch));
    _group(groupId);
    final payload = <String, Object?>{
      if (patch.name != null) GroupFields.name: _cleanName(patch.name!),
      if (patch.type != null) GroupFields.type: patch.type!.name,
      if (patch.currency != null) GroupFields.currency: patch.currency,
      if (patch.emoji != null) GroupFields.emoji: patch.emoji,
      if (patch.simplifyDebts != null)
        GroupFields.simplifyDebts: patch.simplifyDebts,
      if (patch.archived != null) GroupFields.archived: patch.archived,
    };
    if (payload.isEmpty) return;
    _write(groupId, EntityType.group, groupId, OpKind.update, payload);
    _emit();
  }

  @override
  Future<void> deleteGroup(GroupId groupId) async {
    _group(groupId);
    _write(groupId, EntityType.group, groupId, OpKind.delete, {
      GroupFields.deletedAt: _nowMs,
    });
    _emit();
  }

  // ------------------------------------------------------------ members --

  @override
  Future<MemberId> addMember(
    GroupId groupId, {
    required String displayName,
    PersonId? personId,
  }) async {
    _group(groupId);
    final id = _idGen.newId();
    _addMemberOp(
      groupId,
      id,
      _cleanName(displayName),
      personId ?? _idGen.newId(),
    );
    _emit();
    return id;
  }

  @override
  Future<void> renameMember(
    GroupId groupId,
    MemberId memberId,
    String name,
  ) async {
    _member(_group(groupId), memberId);
    _write(groupId, EntityType.member, memberId, OpKind.update, {
      MemberFields.displayName: _cleanName(name),
    });
    _emit();
  }

  @override
  Future<void> removeMember(GroupId groupId, MemberId memberId) async {
    _member(_group(groupId), memberId);
    _write(groupId, EntityType.member, memberId, OpKind.delete, {
      MemberFields.deletedAt: _nowMs,
    });
    _emit();
  }

  @override
  Future<void> mergeMembers(
    GroupId groupId, {
    required MemberId from,
    required MemberId into,
  }) async {
    final g = _group(groupId);
    _member(g, from);
    _member(g, into);
    if (from == into) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'same');
    }
    _write(groupId, EntityType.member, from, OpKind.update, {
      MemberFields.mergedInto: into,
    });
    _emit();
  }

  @override
  Future<void> claimMember(GroupId groupId, MemberId memberId) async {
    claimedMembers.add((groupId, memberId));
    _member(_group(groupId), memberId);
    _write(groupId, EntityType.member, memberId, OpKind.update, {
      MemberFields.personId: _me,
      MemberFields.deviceId: _device,
    });
    _emit();
  }

  @override
  Future<GroupId> directGroupWith({
    required PersonId personId,
    required String displayName,
    required String currency,
  }) async {
    for (final g in _reducer.state.visibleGroups) {
      if (!g.group!.isDirect) continue;
      if (g.memberForPerson(_me) != null &&
          g.memberForPerson(personId) != null) {
        return g.groupId;
      }
    }
    final id = _createGroup(
      name: _cleanName(displayName),
      type: GroupType.direct,
      currency: currency,
      simplify: false,
    );
    _addMemberOp(id, _idGen.newId(), displayName.trim(), personId);
    _emit();
    return id;
  }

  // ----------------------------------------------------------- expenses --

  MoneyBlock _money(
    int total,
    String currency,
    SplitSpec paid,
    SplitSpec owed,
  ) {
    if (total <= 0 || total > 999999999) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'total');
    }
    try {
      return SplitCalculator.buildMoneyBlock(
        total: total,
        currency: currency,
        paidBy: paid,
        owedBy: owed,
      );
    } on SplitException catch (e) {
      throw LedgerException(LedgerErrorCode.invalidSplit, e.message);
    }
  }

  @override
  Future<ExpenseId> addExpense(ExpenseDraft draft) async {
    addedExpenses.add(draft);
    final g = _group(draft.groupId);
    final description = draft.description.trim();
    if (description.isEmpty) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'description');
    }
    final money = _money(
      draft.total,
      draft.currency,
      draft.paidBy,
      draft.owedBy,
    );
    final id = _idGen.newId();
    _write(draft.groupId, EntityType.expense, id, OpKind.create, {
      ExpenseFields.kind: ExpenseKind.expense.name,
      ExpenseFields.description: description,
      ExpenseFields.category: draft.category,
      ExpenseFields.date: draft.date.millisecondsSinceEpoch,
      ExpenseFields.notes: draft.notes,
      ExpenseFields.money: money.toJson(),
      ExpenseFields.createdBy: _myMemberIn(g) ?? money.paid.keys.first,
      ExpenseFields.createdAt: _nowMs,
    });
    _emit();
    return id;
  }

  @override
  Future<void> updateExpense(ExpenseId expenseId, ExpenseDraft draft) async {
    updatedExpenses.add((expenseId, draft));
    final e =
        _reducer.state.expenseIn(draft.groupId, expenseId) ??
        _expense(expenseId);
    final description = draft.description.trim();
    if (description.isEmpty) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'description');
    }
    final money = _money(
      draft.total,
      draft.currency,
      draft.paidBy,
      draft.owedBy,
    );
    final payload = <String, Object?>{
      if (description != e.description) ExpenseFields.description: description,
      if (draft.category != e.category) ExpenseFields.category: draft.category,
      if (!draft.date.isAtSameMomentAs(e.date))
        ExpenseFields.date: draft.date.millisecondsSinceEpoch,
      if (draft.notes != e.notes) ExpenseFields.notes: draft.notes,
      if (!_sameMoney(money, e.money)) ExpenseFields.money: money.toJson(),
    };
    if (payload.isEmpty) return;
    _write(e.groupId, EntityType.expense, expenseId, OpKind.update, payload);
    _emit();
  }

  static bool _sameMoney(MoneyBlock a, MoneyBlock b) =>
      a.total == b.total &&
      a.currency == b.currency &&
      a.paidBy == b.paidBy &&
      a.owedBy == b.owedBy;

  @override
  Future<void> deleteExpense(ExpenseId expenseId, {GroupId? groupId}) async {
    deletedExpenses.add(expenseId);
    final e = _expense(expenseId, groupId: groupId);
    _write(e.groupId, EntityType.expense, expenseId, OpKind.delete, {
      ExpenseFields.deletedAt: _nowMs,
    });
    _emit();
  }

  @override
  Future<void> restoreExpense(ExpenseId expenseId, {GroupId? groupId}) async {
    restoredExpenses.add(expenseId);
    final e = _expense(expenseId, groupId: groupId);
    _write(e.groupId, EntityType.expense, expenseId, OpKind.restore, {
      ExpenseFields.deletedAt: null,
    });
    _emit();
  }

  @override
  Future<ExpenseId> recordPayment(PaymentDraft draft) async {
    recordedPayments.add(draft);
    final g = _group(draft.groupId);
    _member(g, draft.from);
    _member(g, draft.to);
    if (draft.from == draft.to) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'same');
    }
    final money = _paymentMoney(draft);
    final id = _idGen.newId();
    _write(draft.groupId, EntityType.expense, id, OpKind.create, {
      ExpenseFields.kind: ExpenseKind.payment.name,
      ExpenseFields.description: '',
      ExpenseFields.category: 'payment',
      ExpenseFields.date: draft.date.millisecondsSinceEpoch,
      ExpenseFields.notes: draft.notes,
      ExpenseFields.money: money.toJson(),
      ExpenseFields.paymentMethod: draft.method.name,
      ExpenseFields.createdBy: _myMemberIn(g) ?? draft.from,
      ExpenseFields.createdAt: _nowMs,
    });
    _emit();
    return id;
  }

  MoneyBlock _paymentMoney(PaymentDraft d) {
    if (d.amount <= 0 || d.amount > 999999999) {
      throw const LedgerException(LedgerErrorCode.invalidInput, 'amount');
    }
    return SplitCalculator.paymentBlock(
      from: d.from,
      to: d.to,
      amount: d.amount,
      currency: d.currency,
    );
  }

  @override
  Future<void> updatePayment(ExpenseId expenseId, PaymentDraft draft) async {
    final e =
        _reducer.state.expenseIn(draft.groupId, expenseId) ??
        _expense(expenseId);
    final money = _paymentMoney(draft);
    final payload = <String, Object?>{
      if (!_sameMoney(money, e.money)) ExpenseFields.money: money.toJson(),
      if (draft.method != e.paymentMethod)
        ExpenseFields.paymentMethod: draft.method.name,
      if (!draft.date.isAtSameMomentAs(e.date))
        ExpenseFields.date: draft.date.millisecondsSinceEpoch,
      if (draft.notes != e.notes) ExpenseFields.notes: draft.notes,
    };
    if (payload.isEmpty) return;
    _write(e.groupId, EntityType.expense, expenseId, OpKind.update, payload);
    _emit();
  }
}
