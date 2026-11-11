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

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';

import '../core/categories.dart';
import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/name_text.dart';
import '../core/ops.dart';
import '../core/split.dart';
import '../core/version_vector.dart';
import 'codecs.dart';
import 'op_factory.dart';
import 'repositories.dart';
import 'schema.dart';
import 'secure_group_key_store.dart' show kGroupKeyLength;
import 'text_rules.dart';

const String _logName = 'settle_up.data';

final class Ledger implements LedgerRepository, SyncStore {
  Ledger._(
    this._store,
    this._keys,
    this._settings,
    this._ids,
    this._factory,
    this._reducer,
    this._now,
  );

  /// Ops from peers stamped further ahead of this phone's clock than this
  /// are held back (not stored; the peer offers them again next sync).
  /// Within it they are stored and a later local edit still beats them,
  /// so a wrong or hostile clock cannot freeze a field forever.
  static const int maxRemoteAheadMs = 7 * 24 * 60 * 60 * 1000;

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
    final now = nowMillis ?? _wallClock;
    final clock = HlcClock(deviceId: me, last: last, nowMillis: now);
    final factory = OpFactory(
      deviceId: me,
      clock: clock,
      ids: ids,
      lastHlcOf: reducer.lastHlcOf,
    );
    final ledger =
        Ledger._(store, keys, settings, ids, factory, reducer, now);
    await ledger._load(ops);
    return ledger;
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

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
  final int Function() _now;

  /// Every stored op, ascending by (HLC, id).
  final List<Operation> _ops = [];
  List<Operation>? _opsView;

  /// This device's ops per group, ascending by counter.
  final Map<GroupId, List<Operation>> _mine = {};

  /// Highest own counter some peer is known to hold, per group.
  final Map<GroupId, int> _acked = {};

  /// Groups whose stored peer knowledge still claims more of my ops than I
  /// had written, because the cut at open failed (a full or read-only
  /// disk), with the counter it must be cut to. The cut is retried before
  /// the next own op of that group is stored, so a later open never judges
  /// that row against edits written after it (DATA-R4-01).
  final Map<GroupId, int> _uncut = {};

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
    try {
      _keyCache.addAll(await _keys.all());
    } catch (e) {
      // A broken keystore must not stop the app: the ledger still works
      // locally, only sync of those groups is unavailable. One unreadable
      // entry fails the whole read, so try the known groups one by one.
      developer.log('Could not read group keys: $e', name: _logName);
      for (final g in {for (final op in ops) op.groupId}) {
        try {
          final key = await _keys.keyFor(g);
          if (key != null) _keyCache[g] = key;
        } catch (e) {
          developer.log('Could not read the key of group $g: $e',
              name: _logName);
        }
      }
    }
    // Counters come from every stored row, not only the ones that still
    // decode: a corrupt row holding my latest op must not hand its counter
    // to the next command (the store would ignore that op as a fork).
    final groups = {for (final op in ops) op.groupId, ..._keyCache.keys};
    for (final g in groups) {
      _factory.observe(g, await _store.maxCounter(g, me));
      await _loadAcked(g);
    }
    final state = _reducer.state;
    final withOps = {for (final op in ops) op.groupId};
    for (final g in _keyCache.keys.toList()) {
      final hint = await _store.getKv(KvKeys.pending(g));
      if (state.groups[g]?.group != null) {
        if (hint != null) await _clearHint(g);
      } else if (hint != null) {
        _pending[g] = hint;
      } else if (!withOps.contains(g) &&
          (await _store.versionVector(g)).entries.isEmpty &&
          await _store.getKv(KvKeys.purged(g)) == null) {
        await _dropOrphanKey(g);
      } else {
        // Ops but no create op and no hint: still waiting for the group.
        _pending[g] = '';
      }
    }
    _records = await _store.syncRecords(limit: _recordLimit);
    _current = _buildSnapshot();
  }

  /// A key with no op and no invite hint was written by a createGroup (or
  /// an old join) that never committed: nothing refers to it, so it is
  /// neither shown as a join nor offered to peers.
  Future<void> _dropOrphanKey(GroupId g) async {
    _keyCache.remove(g);
    developer.log('Dropped the key of group $g: no ops and no invite',
        name: _logName);
    try {
      await _keys.remove(g);
    } catch (e) {
      developer.log('Could not remove the key of group $g: $e',
          name: _logName);
    }
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
    // One sort beats many mid-list inserts for a large sync batch.
    final bulk = added.length > 64;
    if (bulk) _ops.addAll(added);
    // One rebuild per entity, not per op: a peer's batch of renames of one
    // member normalises the name once (DATA-R15-01).
    _reducer.applyAll(added);
    for (final op in added) {
      if (!bulk) _insertSorted(_ops, op, _byHlc);
      if (op.deviceId == me) {
        _insertSorted(_mine[op.groupId] ??= [], op,
            (a, b) => a.counter.compareTo(b.counter));
        _factory.observe(op.groupId, op.counter);
      }
    }
    if (bulk) _ops.sort(_byHlc);
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
      await _clearHint(g);
    }
  }

  /// Best effort: a hint left behind is harmless (a group that holds its
  /// create op is never shown as a join) and the next open drops it, so a
  /// full disk must not turn it into a failed sync or a failed start
  /// (DATA-R2-01).
  Future<void> _clearHint(GroupId g) async {
    try {
      await _store.setKv(KvKeys.pending(g), null);
    } catch (e) {
      developer.log('Could not clear the invite hint of $g: $e',
          name: _logName);
    }
  }

  /// Best effort: the ops are already stored, and [open] rebuilds the
  /// clock from the newest own op, so a failed save must not turn a
  /// committed command into an error the user would retry.
  Future<void> _saveClock() async {
    try {
      await _store.setKv(KvKeys.hlcLast, _factory.clock.last.encode());
    } catch (e) {
      developer.log('Could not save the clock: $e', name: _logName);
    }
  }

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
    final keyless = <GroupId>{
      for (final gs in state.visibleGroups)
        if (!_keyCache.containsKey(gs.groupId)) gs.groupId,
    };
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
      groupsWithoutKey: Set.unmodifiable(keyless),
    );
  }

  void _emit() {
    _current = _buildSnapshot();
    if (!_snapshots.isClosed) _snapshots.add(_current);
  }

  /// Inserts one command's ops, applies them and publishes them.
  ///
  /// Throws [LedgerErrorCode.storageFailed] when the store refuses the
  /// write (nothing is stored then), or when it ignored some of the ops.
  /// Once the ops are stored the command succeeds: later bookkeeping
  /// failures are logged, not thrown.
  Future<void> _commit(OpBatch batch) async {
    if (batch.isEmpty) return;
    final ops = batch.ops;
    if (_uncut.isNotEmpty) {
      await _retryCuts([for (final op in ops) op.groupId], strict: true);
    }
    final List<Operation> added;
    try {
      added = await _store.insertAll(ops);
    } catch (e, st) {
      developer.log('Could not store ${ops.length} local ops',
          error: e, stackTrace: st, name: _logName);
      throw LedgerException(LedgerErrorCode.storageFailed, '$e');
    }
    batch.commit();
    _integrate(added);
    await _saveClock();
    _emit();
    for (final op in added) {
      _localOps.add(op);
    }
    if (added.length != ops.length) {
      // A counter of this device was already taken on disk. Re-read the
      // counters so the next command does not collide, and say the
      // command did not (fully) land instead of returning a phantom id.
      developer.log(
        'Store ignored ${ops.length - added.length} of ${ops.length} '
        'local ops',
        name: _logName,
      );
      for (final g in {for (final op in ops) op.groupId}) {
        try {
          _factory.observe(g, await _store.maxCounter(g, _me));
        } catch (e) {
          developer.log('Could not read counters of $g: $e', name: _logName);
        }
      }
      throw const LedgerException(
          LedgerErrorCode.storageFailed, 'Some changes were not stored');
    }
  }

  // ---------------------------------------------------------- validation --

  static Never _fail(LedgerErrorCode code, String message,
          [LedgerInputIssue? issue]) =>
      throw LedgerException(code, message, issue);

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

  /// The expense [expenseId], only in [groupId] when given (entity ids are
  /// scoped by group, SPEC 7.2).
  Expense _expense(ExpenseId expenseId, {GroupId? groupId}) =>
      (groupId == null
          ? _reducer.state.expense(expenseId)
          : _reducer.state.expenseIn(groupId, expenseId)) ??
      _fail(LedgerErrorCode.expenseNotFound, 'No expense $expenseId');

  /// The expense a draft for [groupId] edits: the one in that group, else
  /// (to report that expenses cannot change group) the id anywhere.
  Expense _draftTarget(ExpenseId expenseId, GroupId groupId) =>
      _reducer.state.expenseIn(groupId, expenseId) ?? _expense(expenseId);

  /// An id: trimmed and non-empty.
  static String _text(String value, String field) {
    final t = value.trim();
    if (t.isEmpty) _fail(LedgerErrorCode.invalidInput, '$field is empty');
    return t;
  }

  /// User text (SPEC 5.16): cleaned of control, bidi and zero-width
  /// characters, trimmed, non-empty, at most [limit] characters. Line
  /// breaks become spaces unless [multiline].
  static String _line(String value, String field, int limit,
      {bool multiline = false}) {
    final t = TextRules.clean(value, multiline: multiline);
    if (TextRules.isBlank(t)) {
      _fail(LedgerErrorCode.invalidInput, '$field is empty');
    }
    _fit(t, field, limit);
    return t;
  }

  /// Notes: line breaks kept, at most [TextRules.notes] characters.
  static String _notes(String value) {
    final t = TextRules.clean(value, multiline: true);
    _fit(t, 'notes', TextRules.notes);
    return t;
  }

  static void _fit(String t, String field, int limit) {
    final why = TextRules.tooLong(t, limit);
    if (why != null) {
      throw LedgerException(LedgerErrorCode.invalidInput, '$field is $why',
          LedgerInputIssue.tooLong);
    }
  }

  static String _groupName(String v) =>
      _name(v, 'name', TextRules.groupName);

  static String _memberName(String v, String field) =>
      _name(v, field, TextRules.memberName);

  /// A name (SPEC 5.16): stored as it is shown and compared, [NameText.fit]
  /// to [limit] characters (normalised, then cut like a pasted name when
  /// normalising made it longer than the field let through, DATA-R8-01),
  /// with at least one letter or number.
  static String _name(String value, String field, int limit) {
    final t = NameText.fit(value, limit);
    if (!NameText.hasLetterOrNumber(t)) {
      _fail(LedgerErrorCode.invalidInput, '$field is empty');
    }
    final why = TextRules.nameTooLong(value, limit);
    if (why != null) {
      throw LedgerException(LedgerErrorCode.invalidInput, '$field is $why',
          LedgerInputIssue.tooLong);
    }
    return t;
  }

  /// The name of a person this phone already holds (my profile, or a
  /// member of another group picked for a new one) as it goes into a
  /// member op: [NameText.fit] like a typed name. A name saved before
  /// names needed a letter (DATA-R6-02), by an earlier build or by an
  /// older phone, is kept when it shows something by the rule every phone
  /// checks names from peers with ([TextRules.isBlank]), for example
  /// "😎": it is how that person is already shown, and refusing it would
  /// block every new group with them (UIFLOW-R8-02). Null for a name that
  /// shows nothing.
  static String? _knownName(String value) {
    final t = NameText.fit(value, TextRules.memberName);
    if (NameText.hasLetterOrNumber(t)) return t;
    return t.isEmpty || TextRules.isBlank(t) ? null : t;
  }

  /// [_knownName] of a person picked from another group.
  static String _knownMemberName(String value, String field) =>
      _knownName(value) ?? _memberName(value, field);

  /// My profile name as it goes into a member op ([_knownName]). Settings
  /// validate a name when it is saved; one saved before the limits is cut
  /// rather than blocking every new group, and one that shows nothing
  /// (only possible in a row written by an earlier build) falls back to
  /// this phone's name, which is always a valid name, until I change it.
  String _profileName(Profile profile) =>
      _knownName(profile.displayName) ??
      _knownName(_settings.device.deviceName) ??
      _fail(LedgerErrorCode.invalidInput, 'Your name is empty');

  /// [name] as it goes into a member op for [person]. My stored profile
  /// name, when the op adds or renames me under it (Join > "I'm not on the
  /// list" passes it as it is), goes by [_profileName] like New group and
  /// Add friend: a name an earlier build saved with no letter ("\u{1F60E}")
  /// or longer than the limit is how I am shown and must not block a flow
  /// that adds me, with nothing on the screen to change (UIFLOW-R8-02). Any
  /// other name was typed now and goes by the rule for a typed name.
  String _nameFor(String name, PersonId? person, String field) {
    final profile = _settings.profile;
    if (profile != null &&
        person == profile.personId &&
        NameText.normalize(name) == NameText.normalize(profile.displayName)) {
      return _profileName(profile);
    }
    return _memberName(name, field);
  }

  static Never _groupFull() => throw const LedgerException(
        LedgerErrorCode.invalidInput,
        'A group has at most ${TextRules.maxActiveMembers} people',
        LedgerInputIssue.groupFull,
      );


  static String _currency(String code) {
    final c = code.trim().toUpperCase();
    if (!TextRules.currencyPattern.hasMatch(c)) {
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
    final t = emoji == null ? null : TextRules.clean(emoji);
    if (t == null || t.isEmpty) return null;
    if (t.length > TextRules.emoji) {
      _fail(LedgerErrorCode.invalidInput, 'emoji is too long');
    }
    return t;
  }

  /// [date] as stored: UTC milliseconds within the window peers accept
  /// (TextRules.isModelDate), so every phone can show it in local time.
  static int _ms(DateTime date) {
    final ms = date.toUtc().millisecondsSinceEpoch;
    if (!TextRules.isModelDate(ms)) {
      _fail(LedgerErrorCode.invalidInput, 'date $date is out of range');
    }
    return ms;
  }

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
        final name = _groupName(draft.name);
        final currency = _currency(draft.currency);
        final newNames = [
          for (final n in draft.newMemberNames) _memberName(n, 'member name'),
        ];
        final existing = <PersonId, String>{};
        for (final p in draft.existingPeople) {
          final personId = _text(p.personId, 'personId');
          if (personId == profile.personId) continue;
          existing.putIfAbsent(personId,
              () => _knownMemberName(p.displayName, 'member name'));
        }
        if (1 + newNames.length + existing.length >
            TextRules.maxActiveMembers) {
          _groupFull();
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
    final myName = _profileName(profile);
    final groupId = _ids.newId();
    final key = _newKey();
    try {
      await _keys.put(groupId, key);
    } catch (e, st) {
      developer.log('Could not store a group key',
          error: e, stackTrace: st, name: _logName);
      throw LedgerException(LedgerErrorCode.storageFailed, '$e');
    }
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
                MemberFields.displayName: myName,
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
      // Keep the key of a group whose create op did land.
      if (_reducer.state.groups[groupId]?.group == null) {
        _keyCache.remove(groupId);
        try {
          await _keys.remove(groupId);
        } catch (e) {
          developer.log('Could not remove an unused group key: $e',
              name: _logName);
        }
      }
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
          final name = _groupName(patch.name!);
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
        final person = personId == null ? null : _text(personId, 'personId');
        final name = _nameFor(displayName, person, 'displayName');
        // A 1:1 group stays two people.
        if (gs.group?.isDirect ?? false) {
          final known = person != null && gs.memberForPerson(person) != null;
          if (!known && gs.activeMembers.length >= 2) {
            _fail(LedgerErrorCode.invalidInput,
                'A 1:1 group has exactly two people');
          }
        }
        if (person != null) {
          final existing = gs.memberForPerson(person);
          if (existing != null && _isActive(gs, existing)) return existing.id;
        }
        if (gs.activeMembers.length >= TextRules.maxActiveMembers) {
          _groupFull();
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
        final displayName = _nameFor(name, member.personId, 'name');
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
        final name = _knownMemberName(displayName, 'displayName');
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
    // Line breaks are kept: a pasted two-line description round-trips
    // through the CSV export unchanged.
    final description = _line(
        draft.description, 'description', TextRules.description,
        multiline: true);
    final total = _amount(draft.total, 'total');
    final money = _money(
      gs,
      total: total,
      currency: _currency(draft.currency),
      paidBy: draft.paidBy,
      owedBy: draft.owedBy,
    );
    final category = draft.category.trim();
    if (category.length > TextRules.category) {
      _fail(LedgerErrorCode.invalidInput, 'category is too long');
    }
    return {
      ExpenseFields.description: description,
      ExpenseFields.category: category.isEmpty ? Categories.general : category,
      ExpenseFields.date: _ms(draft.date),
      ExpenseFields.notes: _notes(draft.notes),
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
        final expense = _draftTarget(expenseId, draft.groupId);
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
  Future<void> deleteExpense(ExpenseId expenseId, {GroupId? groupId}) =>
      _serial(() async {
        final expense = _expense(expenseId, groupId: groupId);
        _liveGroup(expense.groupId);
        if (expense.isDeleted) return;
        await _commit(_factory.batch()
          ..delete(expense.groupId, EntityType.expense, expenseId));
      });

  @override
  Future<void> restoreExpense(ExpenseId expenseId, {GroupId? groupId}) =>
      _serial(() async {
        final expense = _expense(expenseId, groupId: groupId);
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
      ExpenseFields.notes: _notes(draft.notes),
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
        final expense = _draftTarget(expenseId, draft.groupId);
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
  Stream<String> watchLocalDeviceName() =>
      _settings.watchDevice().map((d) => d.deviceName).distinct();

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
        var units = 0;
        for (final op in ops) {
          units += _checkRemote(groupId, op);
        }
        if (units > TextRules.maxRemoteBatchUnits) {
          throw FormatException('Batch of ${ops.length} ops is $units units, '
              'over ${TextRules.maxRemoteBatchUnits}');
        }
        if (ops.isEmpty) return const <Operation>[];
        await _checkOwnOps(groupId, ops);
        final limit = _now() + maxRemoteAheadMs;
        final accepted = [
          for (final op in ops)
            if (op.hlc.millis <= limit) op,
        ];
        if (accepted.length != ops.length) {
          _factory.clock.skewDetected = true;
          developer.log(
            'Held back ${ops.length - accepted.length} ops stamped more than '
            '${maxRemoteAheadMs ~/ 86400000} days ahead of this phone',
            name: _logName,
          );
        }
        if (accepted.isEmpty) return const <Operation>[];
        final added = await _store.insertAll(accepted);
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

  /// Only this phone writes ops with its device id. A peer may hand back
  /// ones this phone already stored (they are ignored as duplicates) or
  /// removed with purgeGroup (they restore the counter), but one past
  /// this phone's own counter is forged: accepting it would move
  /// the local counter (a gap that never syncs, or a wrap past int64).
  Future<void> _checkOwnOps(GroupId groupId, List<Operation> ops) async {
    final me = _me;
    if (!ops.any((op) => op.deviceId == me)) return;
    final max = await _ownMaxCounter(groupId);
    for (final op in ops) {
      if (op.deviceId == me && op.counter > max) {
        throw FormatException(
            'Op ${op.id} claims this phone as its author', op.id);
      }
    }
  }

  /// How many of my ops in [groupId] some peer holds. A peer cannot hold
  /// more of them than I wrote (SECURITY-R2-01); a stored report that says
  /// so (written before that check, or by a peer then) is cut down on disk
  /// too. Clamped only in memory, every later open would clamp it to what
  /// I had written by then and show those changes as shared (DATA-R3-01).
  Future<void> _loadAcked(GroupId groupId) async {
    final written = await _ownMaxCounter(groupId);
    final known = (await _store.peerKnowledge(groupId))[_me];
    if (known > written) {
      developer.log(
        'Stored peer knowledge claims my ops up to $known in $groupId; '
        'I wrote $written',
        name: _logName,
      );
      try {
        await _store.capPeerKnowledge(groupId, _me, written);
      } catch (e) {
        // A read-only or full disk must not stop the app; the clamp below
        // still holds for this session, and the cut is retried before any
        // new own op of this group is stored (_retryCuts).
        developer.log('Could not fix stored peer knowledge: $e',
            name: _logName);
        _uncut[groupId] = written;
      }
    }
    final acked = math.min(known, written);
    if (acked > 0) _acked[groupId] = acked;
  }

  /// Retries the open-time cuts of [groups] that failed (DATA-R4-01).
  ///
  /// With [strict], a cut that fails again throws
  /// [LedgerErrorCode.storageFailed]: an own op stored past the uncut row
  /// would be shown as shared by the next open, which cuts that row to
  /// what was written by then. The store is failing anyway, so the op
  /// would most likely not have been stored either.
  Future<void> _retryCuts(Iterable<GroupId> groups,
      {required bool strict}) async {
    for (final g in groups.toSet()) {
      final max = _uncut[g];
      if (max == null) continue;
      try {
        await _store.capPeerKnowledge(g, _me, max);
        _uncut.remove(g);
      } catch (e) {
        developer.log('Could not fix stored peer knowledge of $g: $e',
            name: _logName);
        if (strict) {
          throw LedgerException(LedgerErrorCode.storageFailed, '$e');
        }
      }
    }
  }

  /// Highest counter this phone has written in [groupId]: stored ops, or
  /// ones removed by purgeGroup that peers may still hold.
  Future<int> _ownMaxCounter(GroupId groupId) async {
    final purged = purgedMark(await _store.getKv(KvKeys.purged(groupId)));
    return math.max(await _store.maxCounter(groupId, _me), purged[_me] ?? 0);
  }

  /// Throws [FormatException] unless [op] belongs to [groupId], has a valid
  /// counter and HLC device, keeps to the SPEC 5.16 text limits and size,
  /// and survives a JSON round trip unchanged. Returns its JSON length.
  static int _checkRemote(GroupId groupId, Operation op) {
    if (op.groupId != groupId) {
      throw FormatException('Op ${op.id} is for another group', op.groupId);
    }
    if (op.id.isEmpty || op.deviceId.isEmpty || op.entityId.isEmpty) {
      throw FormatException('Op with empty ids', op.id);
    }
    if (op.counter < 1 ||
        op.counter > TextRules.maxCounter ||
        op.hlc.deviceId != op.deviceId) {
      throw FormatException('Op ${op.id} has a bad counter or HLC', op.id);
    }
    final problem = TextRules.remoteProblem(op);
    if (problem != null) {
      throw FormatException('Op ${op.id}: $problem', op.id);
    }
    final Operation parsed;
    final String json;
    try {
      json = jsonEncode(op.toJson());
      if (json.length > TextRules.maxRemoteOpUnits) {
        throw FormatException('Op ${op.id} is too large', op.id);
      }
      parsed = Operation.fromJson(Map<String, Object?>.from(
        jsonDecode(json) as Map,
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
    return json.length;
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) =>
      _serial(() async {
        if (peer == _me) return;
        // Only this phone writes ops with its device id, so a report of
        // more of them than it wrote is forged. Kept as is, it would show
        // every later local change as shared although no phone has it
        // (SECURITY-R2-01).
        var report = vv;
        final claimed = vv[_me];
        if (claimed > 0) {
          final written = await _ownMaxCounter(groupId);
          if (claimed > written) {
            developer.log(
              'Peer $peer claims my ops up to $claimed in $groupId; '
              'I wrote $written',
              name: _logName,
            );
            report = vv.withEntry(_me, written);
          }
        }
        // The merge keeps the larger value, so an uncut row would outlast
        // any honest report.
        if (_uncut.isNotEmpty) await _retryCuts([groupId], strict: false);
        await _store.recordPeerKnowledge(peer, groupId, report);
        final before = _acked[groupId] ?? 0;
        final acked = math.max(before, report[_me]);
        if (acked == before) return;
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
        if (_reducer.state.groups[groupId]?.group != null) {
          await _keys.put(groupId, copy);
          _keyCache[groupId] = copy;
          _emit();
          return false;
        }
        // A group name from another phone's link, in the form group names
        // are shown in ([NameText.display]).
        var hint = NameText.display(nameHint, TextRules.groupName);
        if (TextRules.tooLong(hint, TextRules.groupName) != null) {
          // Only a hint that shows nothing once normalised gets here.
          hint = hint.characters.take(TextRules.groupName).toString().trim();
        }
        // The hint goes first: a key without a hint and without ops is
        // taken for a createGroup that never committed and dropped on open.
        await _store.setKv(KvKeys.pending(groupId), hint);
        try {
          await _keys.put(groupId, copy);
        } catch (_) {
          try {
            await _store.setKv(KvKeys.pending(groupId), null);
          } catch (_) {}
          rethrow;
        }
        _keyCache[groupId] = copy;
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
