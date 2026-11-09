// The Ledger: LedgerRepository for the UI and SyncStore for the sync engine,
// on one op store and one in-memory reducer (docs/SPEC.md 3.1, 5.11, 7).
// Owner: data.
//
// Local write: validate -> build ops (HLC tick + next counter each) ->
// OpStore.insertAll (one transaction) -> reducer -> new snapshot -> the ops
// go out on [localOps]. Remote write: validate the batch -> insertAll ->
// HlcClock.receive(batch max) -> reducer -> new snapshot. Every command and
// every remote batch runs one at a time, in call order.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../core/categories.dart';
import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/ops.dart';
import '../core/split.dart';
import '../core/version_vector.dart';
import 'codecs.dart';
import 'op_factory.dart';
import 'repositories.dart';
import 'schema.dart';
import 'secure_group_key_store.dart' show kGroupKeyLength;

const String _logName = 'settle_up.data';

final class Ledger implements LedgerRepository, SyncStore {
  Ledger._(
    this._store,
    this._keys,
    this._settings,
    this._ids,
    this._factory,
    this._reducer,
  );

  /// Replays the stored op log, restores the HLC (`kv['hlc.last']` merged
  /// with the newest own op) and builds the first snapshot. The store must
  /// already be open; [close] leaves it open (it is shared with settings).
  static Future<Ledger> open({
    required OpStore store,
    required GroupKeyStore keys,
    required SettingsRepository settings,
    IdGenerator ids = const UuidV7Generator(),
    int Function()? nowMillis,
  }) async {
    final me = settings.device.deviceId;
    final ops = await store.loadAll();
    final reducer = LedgerReducer()..applyAll(ops);

    var last = _restoredHlc(await store.getKv(KvKeys.hlcLast), me);
    for (final op in ops) {
      if (op.deviceId == me && op.hlc > last) {
        last = Hlc(op.hlc.millis, op.hlc.counter, me);
      }
    }
    final clock = HlcClock(deviceId: me, last: last, nowMillis: nowMillis);
    final factory = OpFactory(deviceId: me, clock: clock, ids: ids);
    final ledger = Ledger._(store, keys, settings, ids, factory, reducer);
    await ledger._load(ops);
    return ledger;
  }

  /// The stored clock value re-homed on this device (a corrupt or foreign
  /// value only loses its device part; a malformed one is ignored).
  static Hlc _restoredHlc(String? encoded, DeviceId me) {
    if (encoded == null) return Hlc.zero(me);
    try {
      final h = Hlc.parse(encoded);
      if (h.millis < 0 || h.counter < 0 || h.counter > Hlc.maxCounter) {
        return Hlc.zero(me);
      }
      return Hlc(h.millis, h.counter, me);
    } on FormatException {
      return Hlc.zero(me);
    }
  }

  final OpStore _store;
  final GroupKeyStore _keys;
  final SettingsRepository _settings;
  final IdGenerator _ids;
  final OpFactory _factory;
  final LedgerReducer _reducer;

  /// Every stored op, ascending by (HLC, id).
  final List<Operation> _ops = [];
  List<Operation>? _opsView;

  /// This device's ops per group, ascending by counter.
  final Map<GroupId, List<Operation>> _mine = {};

  /// Highest own counter some peer is known to hold, per group.
  final Map<GroupId, int> _acked = {};

  final Map<GroupId, Uint8List> _keyCache = {};

  /// Name hints of groups joined by invite (kv `pending.<groupId>`).
  final Map<GroupId, String> _pending = {};

  List<SyncRecord> _records = const [];
  static const int _recordLimit = 50;

  final StreamController<LedgerSnapshot> _snapshots =
      StreamController.broadcast(sync: true);
  final StreamController<Operation> _localOps = StreamController.broadcast();
  final StreamController<List<SyncRecord>> _recordChanges =
      StreamController.broadcast(sync: true);

  late LedgerSnapshot _current;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _skewLogged = false;

  DeviceId get _me => _settings.device.deviceId;

  /// True once a peer's clock was seen more than an hour ahead of ours
  /// (Settings shows "This phone's clock looks wrong").
  bool get clockSkewDetected => _factory.clock.skewDetected;

  Future<void> _load(List<Operation> ops) async {
    final me = _me;
    _ops
      ..addAll(ops)
      ..sort(_byHlc);
    for (final op in ops) {
      if (op.deviceId != me) continue;
      (_mine[op.groupId] ??= []).add(op);
      _factory.observe(op.groupId, op.counter);
    }
    for (final list in _mine.values) {
      list.sort((a, b) => a.counter.compareTo(b.counter));
    }
    for (final g in _mine.keys) {
      _acked[g] = (await _store.peerKnowledge(g))[me];
    }
    _keyCache.addAll(await _keys.all());
    final state = _reducer.state;
    for (final g in _keyCache.keys) {
      final hint = await _store.getKv(KvKeys.pending(g));
      if (state.groups[g]?.group != null) {
        if (hint != null) await _store.setKv(KvKeys.pending(g), null);
      } else {
        _pending[g] = hint ?? '';
      }
    }
    _records = await _store.syncRecords(limit: _recordLimit);
    _current = _buildSnapshot();
  }

  static int _byHlc(Operation a, Operation b) {
    final c = a.hlc.compareTo(b.hlc);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// Waits for queued commands, then completes every stream. Later calls
  /// throw [StateError]. The op store stays open.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    await _snapshots.close();
    await _localOps.close();
    await _recordChanges.close();
  }

  // ------------------------------------------------------------ plumbing --

  /// Runs [body] after every earlier command (commands are serialized).
  Future<T> _serial<T>(Future<T> Function() body) {
    if (_closed) return Future.error(StateError('Ledger is closed'));
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _integrate(List<Operation> added) {
    final me = _me;
    for (final op in added) {
      _reducer.apply(op);
      _insertSorted(_ops, op, _byHlc);
      if (op.deviceId == me) {
        _insertSorted(_mine[op.groupId] ??= [], op,
            (a, b) => a.counter.compareTo(b.counter));
        _factory.observe(op.groupId, op.counter);
      }
    }
    _opsView = null;
  }

  static void _insertSorted(
    List<Operation> list,
    Operation op,
    int Function(Operation, Operation) compare,
  ) {
    if (list.isEmpty || compare(list.last, op) <= 0) {
      list.add(op);
      return;
    }
    list.insert(lowerBound(list, op, compare: compare), op);
  }

  /// Drops the pending-join hint of every group whose create op arrived.
  Future<void> _settlePending() async {
    final state = _reducer.state;
    final done = [
      for (final g in _pending.keys)
        if (state.groups[g]?.group != null) g,
    ];
    for (final g in done) {
      _pending.remove(g);
      await _store.setKv(KvKeys.pending(g), null);
    }
  }

  Future<void> _saveClock() =>
      _store.setKv(KvKeys.hlcLast, _factory.clock.last.encode());

  LedgerSnapshot _buildSnapshot() {
    final unshared = <OpId>{};
    final counts = <GroupId, int>{};
    _mine.forEach((g, list) {
      final acked = _acked[g] ?? 0;
      var n = 0;
      for (var i = list.length - 1; i >= 0 && list[i].counter > acked; i--) {
        unshared.add(list[i].id);
        n++;
      }
      if (n > 0) counts[g] = n;
    });
    final state = _reducer.state;
    return LedgerSnapshot(
      state: state,
      ops: _opsView ??= List.unmodifiable(_ops),
      pendingJoins: Map.unmodifiable({
        for (final e in _pending.entries)
          if (state.groups[e.key]?.group == null) e.key: e.value,
      }),
      unsharedOpIds: Set.unmodifiable(unshared),
      unsharedCounts: Map.unmodifiable(counts),
      localDeviceId: _me,
    );
  }

  void _emit() {
    _current = _buildSnapshot();
    if (!_snapshots.isClosed) _snapshots.add(_current);
  }

  /// Inserts one command's ops, applies them and publishes them.
  Future<void> _commit(OpBatch batch) async {
    if (batch.isEmpty) return;
    final ops = batch.ops;
    final added = await _store.insertAll(ops);
    batch.commit();
    if (added.length != ops.length) {
      developer.log(
        'Store ignored ${ops.length - added.length} of ${ops.length} '
        'local ops',
        name: _logName,
      );
    }
    _integrate(added);
    await _saveClock();
    _emit();
    for (final op in added) {
      _localOps.add(op);
    }
  }

  // ---------------------------------------------------------- validation --

  static Never _fail(LedgerErrorCode code, String message) =>
      throw LedgerException(code, message);

  Profile _profile() =>
      _settings.profile ??
      _fail(LedgerErrorCode.notOnboarded, 'Complete onboarding first');

  /// A group with a create op that is not deleted.
  GroupState _liveGroup(GroupId groupId) {
    final gs = _reducer.state.groups[groupId];
    final group = gs?.group;
    if (gs == null || group == null || group.isDeleted) {
      _fail(LedgerErrorCode.groupNotFound, 'No group $groupId');
    }
    return gs;
  }

  static Member _member(GroupState gs, MemberId memberId) =>
      gs.members[memberId] ??
      _fail(LedgerErrorCode.memberNotFound,
          'No member $memberId in ${gs.groupId}');

  Expense _expense(ExpenseId expenseId) =>
      _reducer.state.expense(expenseId) ??
      _fail(LedgerErrorCode.expenseNotFound, 'No expense $expenseId');

  static String _text(String value, String field) {
    final t = value.trim();
    if (t.isEmpty) _fail(LedgerErrorCode.invalidInput, '$field is empty');
    return t;
  }

  static final RegExp _currencyPattern = RegExp(r'^[A-Z]{3}$');

  static String _currency(String code) {
    final c = code.trim().toUpperCase();
    if (!_currencyPattern.hasMatch(c)) {
      _fail(LedgerErrorCode.invalidInput, 'Bad currency "$code"');
    }
    return c;
  }

  static int _amount(int minor, String field) {
    if (minor < 1 || minor > Money.maxMinor) {
      _fail(LedgerErrorCode.invalidInput, '$field $minor out of range');
    }
    return minor;
  }

  static String? _emoji(String? emoji) {
    final t = emoji?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  static int _ms(DateTime date) => date.toUtc().millisecondsSinceEpoch;

  static MoneyBlock _money(
    GroupState gs, {
    required int total,
    required String currency,
    required SplitSpec paidBy,
    required SplitSpec owedBy,
  }) {
    for (final m in {...paidBy.values.keys, ...owedBy.values.keys}) {
      _member(gs, m);
    }
    try {
      return SplitCalculator.buildMoneyBlock(
        total: total,
        currency: currency,
        paidBy: paidBy,
        owedBy: owedBy,
      );
    } on SplitException catch (e) {
      throw LedgerException(LedgerErrorCode.invalidSplit, e.toString());
    }
  }

  /// The member that stands for this device in [gs]: claimed by this
  /// device, else carrying my personId, else [fallback].
  MemberId _actor(GroupState gs, MemberId fallback) {
    final me = _me;
    final claimed = gs.members.values
        .where((m) => m.deviceId == me && !m.isRemoved)
        .map((m) => m.id)
        .sorted((a, b) => a.compareTo(b));
    if (claimed.isNotEmpty) return claimed.first;
    final personId = _settings.profile?.personId;
    final mine = personId == null ? null : gs.memberForPerson(personId);
    return mine?.id ?? fallback;
  }

  static bool _isActive(GroupState gs, Member m) =>
      !m.isRemoved && gs.resolve(m.id) == m.id;

  static Uint8List _newKey() {
    final r = math.Random.secure();
    return Uint8List.fromList(
        List<int>.generate(kGroupKeyLength, (_) => r.nextInt(256)));
  }

  static const DeepCollectionEquality _deep = DeepCollectionEquality();

  // ------------------------------------------------------ LedgerRepository --

  @override
  LedgerSnapshot get current => _current;

  @override
  Stream<LedgerSnapshot> watch() => Stream.multi((c) {
        c.add(_current);
        final sub = _snapshots.stream.listen(c.add, onDone: c.close);
        c.onCancel = sub.cancel;
      });

  @override
  Future<GroupId> createGroup(NewGroup draft) => _serial(() async {
        final profile = _profile();
        if (draft.type == GroupType.direct) {
          _fail(LedgerErrorCode.invalidInput, 'Use directGroupWith');
        }
        final name = _text(draft.name, 'name');
        final currency = _currency(draft.currency);
        final newNames = [
          for (final n in draft.newMemberNames) _text(n, 'member name'),
        ];
        final existing = <PersonId, String>{};
        for (final p in draft.existingPeople) {
          final personId = _text(p.personId, 'personId');
          if (personId == profile.personId) continue;
          existing.putIfAbsent(
              personId, () => _text(p.displayName, 'member name'));
        }
        return _createGroup(
          name: name,
          type: draft.type,
          currency: currency,
          emoji: _emoji(draft.emoji),
          simplifyDebts:
              draft.simplifyDebts ?? _settings.settings.simplifyByDefault,
          profile: profile,
          others: [
            for (final n in newNames) (personId: _ids.newId(), name: n),
            for (final e in existing.entries)
              (personId: e.key, name: e.value),
          ],
        );
      });

  Future<GroupId> _createGroup({
    required String name,
    required GroupType type,
    required String currency,
    required String? emoji,
    required bool simplifyDebts,
    required Profile profile,
    required List<({PersonId personId, String name})> others,
  }) async {
    final groupId = _ids.newId();
    final key = _newKey();
    await _keys.put(groupId, key);
    _keyCache[groupId] = key;
    final batch = _factory.batch()
      ..create(groupId, EntityType.group, groupId, GroupFields.required,
          (now) => {
                GroupFields.name: name,
                GroupFields.type: type.name,
                GroupFields.currency: currency,
                GroupFields.simplifyDebts: simplifyDebts,
                GroupFields.emoji: ?emoji,
                GroupFields.archived: false,
                GroupFields.createdAt: now,
              })
      ..create(groupId, EntityType.member, _ids.newId(),
          MemberFields.required, (now) => {
                MemberFields.displayName: profile.displayName,
                MemberFields.personId: profile.personId,
                MemberFields.deviceId: _me,
                MemberFields.createdAt: now,
              });
    for (final o in others) {
      batch.create(groupId, EntityType.member, _ids.newId(),
          MemberFields.required, (now) => {
                MemberFields.displayName: o.name,
                MemberFields.personId: o.personId,
                MemberFields.createdAt: now,
              });
    }
    try {
      await _commit(batch);
    } catch (_) {
      _keyCache.remove(groupId);
      await _keys.remove(groupId);
      rethrow;
    }
    return groupId;
  }

  @override
  Future<void> updateGroup(GroupId groupId, GroupPatch patch) =>
      _serial(() async {
        final group = _liveGroup(groupId).group!;
        final fields = <String, Object?>{};
        if (patch.name != null) {
          final name = _text(patch.name!, 'name');
          if (name != group.name) fields[GroupFields.name] = name;
        }
        final type = patch.type;
        if (type != null && type != group.type) {
          if (type == GroupType.direct || group.isDirect) {
            _fail(LedgerErrorCode.invalidInput, 'Direct groups keep their type');
          }
          fields[GroupFields.type] = type.name;
        }
        if (patch.currency != null) {
          final currency = _currency(patch.currency!);
          if (currency != group.currency) {
            fields[GroupFields.currency] = currency;
          }
        }
        if (patch.emoji != null) {
          final emoji = _emoji(patch.emoji);
          if (emoji != group.emoji) fields[GroupFields.emoji] = emoji;
        }
        final simplify = patch.simplifyDebts;
        if (simplify != null && simplify != group.simplifyDebts) {
          fields[GroupFields.simplifyDebts] = simplify;
        }
        final archived = patch.archived;
        if (archived != null && archived != group.archived) {
          fields[GroupFields.archived] = archived;
        }
        if (fields.isEmpty) return;
        await _commit(_factory.batch()
          ..update(groupId, EntityType.group, groupId, fields));
      });

  @override
  Future<void> deleteGroup(GroupId groupId) => _serial(() async {
        _liveGroup(groupId);
        await _commit(
            _factory.batch()..delete(groupId, EntityType.group, groupId));
      });

  @override
  Future<MemberId> addMember(
    GroupId groupId, {
    required String displayName,
    PersonId? personId,
  }) =>
      _serial(() async {
        final gs = _liveGroup(groupId);
        final name = _text(displayName, 'displayName');
        final person = personId == null ? null : _text(personId, 'personId');
        if (person != null) {
          final existing = gs.memberForPerson(person);
          if (existing != null && _isActive(gs, existing)) return existing.id;
        }
        final memberId = _ids.newId();
        await _commit(_factory.batch()
          ..create(groupId, EntityType.member, memberId, MemberFields.required,
              (now) => {
                    MemberFields.displayName: name,
                    MemberFields.personId: person ?? _ids.newId(),
                    MemberFields.createdAt: now,
                  }));
        return memberId;
      });

  @override
  Future<void> renameMember(
    GroupId groupId,
    MemberId memberId,
    String name,
  ) =>
      _serial(() async {
        final member = _member(_liveGroup(groupId), memberId);
        final displayName = _text(name, 'name');
        if (displayName == member.displayName) return;
        await _commit(_factory.batch()
          ..update(groupId, EntityType.member, memberId,
              {MemberFields.displayName: displayName}));
      });

  /// Tombstones the member. Not blocked by a non-zero balance (SPEC 6.7):
  /// the UI checks that.
  @override
  Future<void> removeMember(GroupId groupId, MemberId memberId) =>
      _serial(() async {
        final member = _member(_liveGroup(groupId), memberId);
        if (member.isRemoved) return;
        await _commit(
            _factory.batch()..delete(groupId, EntityType.member, memberId));
      });

  @override
  Future<void> mergeMembers(
    GroupId groupId, {
    required MemberId from,
    required MemberId into,
  }) =>
      _serial(() async {
        final gs = _liveGroup(groupId);
        _member(gs, from);
        final target = _member(gs, into);
        if (from == into || gs.resolve(from) == gs.resolve(into)) {
          _fail(LedgerErrorCode.invalidInput, 'Members are already merged');
        }
        if (target.isRemoved) {
          _fail(LedgerErrorCode.invalidInput, 'Cannot merge into a removed member');
        }
        await _commit(_factory.batch()
          ..update(groupId, EntityType.member, from,
              {MemberFields.mergedInto: into}));
      });

  /// Also releases any other member this device had claimed in the group
  /// (it gets a fresh personId and no device), so "Which one are you?" can
  /// be answered again.
  @override
  Future<void> claimMember(GroupId groupId, MemberId memberId) =>
      _serial(() async {
        final profile = _profile();
        final gs = _liveGroup(groupId);
        final member = _member(gs, memberId);
        if (member.isRemoved) {
          _fail(LedgerErrorCode.invalidInput, 'Cannot claim a removed member');
        }
        final me = _me;
        final batch = _factory.batch();
        for (final other in gs.members.values.sorted((a, b) => a.id.compareTo(b.id))) {
          if (other.id == memberId || other.deviceId != me || other.isRemoved) {
            continue;
          }
          batch.update(groupId, EntityType.member, other.id, {
            MemberFields.personId: _ids.newId(),
            MemberFields.deviceId: null,
          });
        }
        final fields = <String, Object?>{
          if (member.personId != profile.personId)
            MemberFields.personId: profile.personId,
          if (member.deviceId != me) MemberFields.deviceId: me,
        };
        if (fields.isNotEmpty) {
          batch.update(groupId, EntityType.member, memberId, fields);
        }
        await _commit(batch);
      });

  @override
  Future<GroupId> directGroupWith({
    required PersonId personId,
    required String displayName,
    required String currency,
  }) =>
      _serial(() async {
        final profile = _profile();
        final friend = _text(personId, 'personId');
        if (friend == profile.personId) {
          _fail(LedgerErrorCode.invalidInput, 'That is you');
        }
        final name = _text(displayName, 'displayName');
        final code = _currency(currency);
        final found = <GroupId>[];
        for (final gs in _reducer.state.visibleGroups) {
          if (!gs.group!.isDirect) continue;
          final a = gs.memberForPerson(profile.personId);
          final b = gs.memberForPerson(friend);
          if (a != null && b != null && !a.isRemoved && !b.isRemoved) {
            found.add(gs.groupId);
          }
        }
        if (found.isNotEmpty) return found.min;
        return _createGroup(
          name: name,
          type: GroupType.direct,
          currency: code,
          emoji: null,
          simplifyDebts: _settings.settings.simplifyByDefault,
          profile: profile,
          others: [(personId: friend, name: name)],
        );
      });

  /// Validated payload fields shared by add and update.
  Map<String, Object?> _expenseFields(GroupState gs, ExpenseDraft draft) {
    final description = _text(draft.description, 'description');
    final total = _amount(draft.total, 'total');
    final money = _money(
      gs,
      total: total,
      currency: _currency(draft.currency),
      paidBy: draft.paidBy,
      owedBy: draft.owedBy,
    );
    final category = draft.category.trim();
    return {
      ExpenseFields.description: description,
      ExpenseFields.category: category.isEmpty ? Categories.general : category,
      ExpenseFields.date: _ms(draft.date),
      ExpenseFields.notes: draft.notes.trim(),
      ExpenseFields.money: money.toJson(),
    };
  }

  @override
  Future<ExpenseId> addExpense(ExpenseDraft draft) => _serial(() async {
        final gs = _liveGroup(draft.groupId);
        final fields = _expenseFields(gs, draft);
        final payer = draft.paidBy.values.keys.sorted((a, b) => a.compareTo(b));
        final createdBy = _actor(gs, payer.first);
        final expenseId = _ids.newId();
        await _commit(_factory.batch()
          ..create(draft.groupId, EntityType.expense, expenseId,
              ExpenseFields.required, (now) => {
                    ExpenseFields.kind: ExpenseKind.expense.name,
                    ...fields,
                    ExpenseFields.createdBy: createdBy,
                    ExpenseFields.createdAt: now,
                  }));
        return expenseId;
      });

  /// Fields of [next] whose value differs from [current] (deep equality,
  /// so the money block compares by content).
  static Map<String, Object?> _changed(
    Map<String, Object?> current,
    Map<String, Object?> next,
  ) =>
      {
        for (final e in next.entries)
          if (!_deep.equals(current[e.key], e.value)) e.key: e.value,
      };

  static Map<String, Object?> _currentFields(Expense e) => {
        ExpenseFields.description: e.description,
        ExpenseFields.category: e.category,
        ExpenseFields.date: e.date.millisecondsSinceEpoch,
        ExpenseFields.notes: e.notes,
        ExpenseFields.money: e.money.toJson(),
        ExpenseFields.paymentMethod: e.paymentMethod?.name,
      };

  @override
  Future<void> updateExpense(ExpenseId expenseId, ExpenseDraft draft) =>
      _serial(() async {
        final expense = _expense(expenseId);
        if (expense.isPayment) {
          _fail(LedgerErrorCode.invalidInput, 'Use updatePayment');
        }
        if (draft.groupId != expense.groupId) {
          _fail(LedgerErrorCode.invalidInput, 'Expenses cannot change group');
        }
        final gs = _liveGroup(expense.groupId);
        final fields =
            _changed(_currentFields(expense), _expenseFields(gs, draft));
        if (fields.isEmpty) return;
        await _commit(_factory.batch()
          ..update(expense.groupId, EntityType.expense, expenseId, fields));
      });

  @override
  Future<void> deleteExpense(ExpenseId expenseId) => _serial(() async {
        final expense = _expense(expenseId);
        _liveGroup(expense.groupId);
        if (expense.isDeleted) return;
        await _commit(_factory.batch()
          ..delete(expense.groupId, EntityType.expense, expenseId));
      });

  @override
  Future<void> restoreExpense(ExpenseId expenseId) => _serial(() async {
        final expense = _expense(expenseId);
        _liveGroup(expense.groupId);
        if (!expense.isDeleted) return;
        await _commit(_factory.batch()
          ..restore(expense.groupId, EntityType.expense, expenseId));
      });

  Map<String, Object?> _paymentFields(GroupState gs, PaymentDraft draft) {
    _member(gs, draft.from);
    _member(gs, draft.to);
    if (draft.from == draft.to) {
      _fail(LedgerErrorCode.invalidInput, 'A payment needs two people');
    }
    final amount = _amount(draft.amount, 'amount');
    final currency = _currency(draft.currency);
    final MoneyBlock money;
    try {
      money = SplitCalculator.paymentBlock(
        from: draft.from,
        to: draft.to,
        amount: amount,
        currency: currency,
      );
    } on SplitException catch (e) {
      throw LedgerException(LedgerErrorCode.invalidSplit, e.toString());
    }
    return {
      ExpenseFields.date: _ms(draft.date),
      ExpenseFields.notes: draft.notes.trim(),
      ExpenseFields.money: money.toJson(),
      ExpenseFields.paymentMethod: draft.method.name,
    };
  }

  @override
  Future<ExpenseId> recordPayment(PaymentDraft draft) => _serial(() async {
        final gs = _liveGroup(draft.groupId);
        final fields = _paymentFields(gs, draft);
        final createdBy = _actor(gs, draft.from);
        final expenseId = _ids.newId();
        await _commit(_factory.batch()
          ..create(draft.groupId, EntityType.expense, expenseId,
              ExpenseFields.required, (now) => {
                    ExpenseFields.kind: ExpenseKind.payment.name,
                    ExpenseFields.description: '',
                    ExpenseFields.category: Categories.payment,
                    ...fields,
                    ExpenseFields.createdBy: createdBy,
                    ExpenseFields.createdAt: now,
                  }));
        return expenseId;
      });

  @override
  Future<void> updatePayment(ExpenseId expenseId, PaymentDraft draft) =>
      _serial(() async {
        final expense = _expense(expenseId);
        if (!expense.isPayment) {
          _fail(LedgerErrorCode.invalidInput, 'Use updateExpense');
        }
        if (draft.groupId != expense.groupId) {
          _fail(LedgerErrorCode.invalidInput, 'Payments cannot change group');
        }
        final gs = _liveGroup(expense.groupId);
        final fields =
            _changed(_currentFields(expense), _paymentFields(gs, draft));
        if (fields.isEmpty) return;
        await _commit(_factory.batch()
          ..update(expense.groupId, EntityType.expense, expenseId, fields));
      });

  // ------------------------------------------------------------ SyncStore --

  @override
  DeviceId get localDeviceId => _me;

  @override
  String get localDeviceName => _settings.device.deviceName;

  @override
  Future<Map<GroupId, Uint8List>> groupKeys() async => {
        for (final e in _keyCache.entries) e.key: Uint8List.fromList(e.value),
      };

  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      _store.versionVector(groupId);

  @override
  Future<List<Operation>> opsMissingFor(GroupId groupId, VersionVector peer) =>
      _store.missingFor(groupId, peer);

  @override
  Future<List<Operation>> applyRemote(GroupId groupId, List<Operation> ops) =>
      _serial(() async {
        if (!_keyCache.containsKey(groupId)) {
          throw FormatException('No key held for group', groupId);
        }
        for (final op in ops) {
          _checkRemote(groupId, op);
        }
        if (ops.isEmpty) return const <Operation>[];
        final added = await _store.insertAll(ops);
        if (added.isEmpty) return const <Operation>[];
        _factory.clock.receive(added.map((op) => op.hlc).max);
        if (_factory.clock.skewDetected && !_skewLogged) {
          _skewLogged = true;
          developer.log(
            'A peer clock is more than an hour ahead of this phone',
            name: _logName,
          );
        }
        _integrate(added);
        await _saveClock();
        await _settlePending();
        _emit();
        return added;
      });

  /// Throws [FormatException] unless [op] belongs to [groupId], has a valid
  /// counter and HLC device, and survives a JSON round trip unchanged.
  static void _checkRemote(GroupId groupId, Operation op) {
    if (op.groupId != groupId) {
      throw FormatException('Op ${op.id} is for another group', op.groupId);
    }
    if (op.id.isEmpty || op.deviceId.isEmpty || op.entityId.isEmpty) {
      throw FormatException('Op with empty ids', op.id);
    }
    if (op.counter < 1 || op.hlc.deviceId != op.deviceId) {
      throw FormatException('Op ${op.id} has a bad counter or HLC', op.id);
    }
    final Operation parsed;
    try {
      parsed = Operation.fromJson(Map<String, Object?>.from(
        jsonDecode(jsonEncode(op.toJson())) as Map,
      ));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Op ${op.id} is not valid JSON: $e', op.id);
    }
    if (parsed.id != op.id ||
        parsed.groupId != op.groupId ||
        parsed.deviceId != op.deviceId ||
        parsed.counter != op.counter ||
        parsed.hlc != op.hlc) {
      throw FormatException('Op ${op.id} does not match its JSON', op.id);
    }
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) =>
      _serial(() async {
        if (peer == _me) return;
        await _store.recordPeerKnowledge(peer, groupId, vv);
        final acked = (await _store.peerKnowledge(groupId))[_me];
        if (acked == (_acked[groupId] ?? 0)) return;
        _acked[groupId] = acked;
        _emit();
      });

  @override
  Stream<Operation> get localOps => _localOps.stream;

  @override
  Future<bool> registerJoinedGroup(
    GroupId groupId,
    Uint8List key,
    String nameHint,
  ) =>
      _serial(() async {
        if (key.length != kGroupKeyLength) {
          throw ArgumentError.value(
              key.length, 'key', 'group keys are $kGroupKeyLength bytes');
        }
        if (_keyCache.containsKey(groupId)) return false;
        final copy = Uint8List.fromList(key);
        await _keys.put(groupId, copy);
        _keyCache[groupId] = copy;
        if (_reducer.state.groups[groupId]?.group != null) {
          _emit();
          return false;
        }
        final hint = nameHint.trim();
        await _store.setKv(KvKeys.pending(groupId), hint);
        _pending[groupId] = hint;
        _emit();
        return true;
      });

  @override
  Future<void> addSyncRecord(SyncRecord record) => _serial(() async {
        await _store.addSyncRecord(record);
        _records = ([
          record,
          for (final r in _records)
            if (r.id != record.id) r,
        ]..sort(compareSyncRecordsNewestFirst))
            .take(_recordLimit)
            .toList(growable: false);
        if (!_recordChanges.isClosed) {
          _recordChanges.add(List.unmodifiable(_records));
        }
      });

  @override
  Stream<List<SyncRecord>> watchSyncRecords() => Stream.multi((c) {
        c.add(List.unmodifiable(_records));
        final sub = _recordChanges.stream.listen(c.add, onDone: c.close);
        c.onCancel = sub.cancel;
      });
}
