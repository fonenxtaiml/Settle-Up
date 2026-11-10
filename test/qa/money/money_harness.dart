// QA MONEY harness: one simulated phone on the real data layer
// (Ledger over MemoryOpStore, KvSettingsRepository, MemoryGroupKeyStore)
// with the real Riverpod providers on top, plus the money invariants every
// scenario re-checks after each command.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';

/// 2026-11-09T00:00:00Z
const int kBaseMs = 1794182400000;

/// Ids from [preset] first (in order), then unique sequential ones under
/// [prefix]. Lets a test decide which member gets the lowest id.
final class ScriptedIds implements IdGenerator {
  ScriptedIds(this.prefix, [List<String> preset = const []])
    : _preset = List.of(preset);
  final String prefix; // 8 hex chars
  final List<String> _preset;
  int _n = 0;

  void queue(Iterable<String> ids) => _preset.addAll(ids);

  @override
  String newId() {
    if (_preset.isNotEmpty) return _preset.removeAt(0);
    final n = (++_n).toRadixString(16).padLeft(12, '0');
    return '$prefix-0000-7000-8000-$n';
  }
}

final class QaPhone {
  QaPhone._(
    this.store,
    this.settings,
    this.ledger,
    this.ids,
    this.container,
    this._clock,
  );

  final MemoryOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;
  final ScriptedIds ids;
  final ProviderContainer container;
  int _clock;

  static Future<QaPhone> create({
    String name = 'Alex',
    String home = 'INR',
    String prefix = 'aaaaaaaa',
  }) async {
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: '$name phone',
      ids: ScriptedIds('${prefix.substring(0, 4)}ffff'),
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: name, homeCurrency: home);
    final ids = ScriptedIds(prefix);
    late QaPhone phone;
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () => phone._clock,
    );
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settings),
        ledgerRepositoryProvider.overrideWithValue(ledger),
        syncEngineProvider.overrideWithValue(FakeSyncEngine()),
      ],
    );
    phone = QaPhone._(store, settings, ledger, ids, container, kBaseMs);
    container.listen(ledgerProvider, (_, _) {});
    container.listen(profileProvider, (_, _) {});
    await pumpEventQueue();
    return phone;
  }

  Future<void> dispose() async {
    container.dispose();
    await ledger.close();
  }

  void tick([int ms = 1000]) => _clock += ms;

  PersonId get me => settings.profile!.personId;
  LedgerState get state => ledger.current.state;
  GroupState gs(GroupId g) => state.groups[g]!;

  /// Creates a group with me plus [others]; returns ids by display name
  /// (mine under 'me').
  Future<({GroupId g, Map<String, MemberId> m})> group(
    List<String> others, {
    String currency = 'INR',
    bool simplify = true,
    GroupType type = GroupType.trip,
  }) async {
    final g = await ledger.createGroup(
      NewGroup(
        name: 'Trip',
        type: type,
        currency: currency,
        simplifyDebts: simplify,
        newMemberNames: others,
      ),
    );
    final s = gs(g);
    final m = <String, MemberId>{};
    for (final mem in s.members.values) {
      m[mem.personId == me ? 'me' : mem.displayName] = mem.id;
    }
    return (g: g, m: m);
  }

  Future<ExpenseId> add(
    GroupId g, {
    required int total,
    required SplitSpec paidBy,
    required SplitSpec owedBy,
    String currency = 'INR',
    String description = 'Dinner',
    int dateMs = kBaseMs,
  }) async {
    tick();
    final id = await ledger.addExpense(
      ExpenseDraft(
        groupId: g,
        description: description,
        total: total,
        currency: currency,
        paidBy: paidBy,
        owedBy: owedBy,
        category: 'food.dining',
        date: utcFromMillis(dateMs),
      ),
    );
    await pumpEventQueue();
    return id;
  }

  Future<ExpenseId> pay(
    GroupId g, {
    required MemberId from,
    required MemberId to,
    required int amount,
    String currency = 'INR',
    int dateMs = kBaseMs,
  }) async {
    tick();
    final id = await ledger.recordPayment(
      PaymentDraft(
        groupId: g,
        from: from,
        to: to,
        amount: amount,
        currency: currency,
        method: PaymentMethod.cash,
        date: utcFromMillis(dateMs),
      ),
    );
    await pumpEventQueue();
    return id;
  }

  // ------------------------------------------------- provider read-outs --

  NetsByCurrency nets(GroupId g) => container.read(groupNetsProvider(g)).value!;
  List<Transfer> transfers(GroupId g) =>
      container.read(groupTransfersProvider(g)).value!;
  List<PersonBalance> people() => container.read(peopleBalancesProvider).value!;
  OverallBalance overall() => container.read(overallBalanceProvider).value!;
  List<GroupBalanceSummary> summaries() =>
      container.read(groupSummariesProvider).value!;

  /// Shares owed by each member of one expense.
  Map<MemberId, int> owed(ExpenseId id) => state.expense(id)!.money.owed;
  Map<MemberId, int> paid(ExpenseId id) => state.expense(id)!.money.paid;
}

/// Every money invariant the charter asks for, over the providers.
void expectMoneyInvariants(QaPhone p, {String reason = ''}) {
  final state = p.state;
  final why = reason.isEmpty ? '' : ' ($reason)';
  final myNetSum = <String, int>{};
  for (final g in state.visibleGroups) {
    final nets = p.nets(g.groupId);
    expect(
      nets,
      BalanceCalculator.groupNets(g),
      reason: 'groupNetsProvider == core$why',
    );
    nets.forEach((c, byMember) {
      expect(
        byMember.values.fold(0, (a, b) => a + b),
        0,
        reason: 'nets of $c sum to zero in ${g.groupId}$why',
      );
      expect(
        byMember.values.every((v) => v != 0),
        isTrue,
        reason: 'no zero entries$why',
      );
    });
    for (final e in g.liveExpenses) {
      final m = e.money;
      expect(
        m.paid.values.fold(0, (a, b) => a + b),
        m.total,
        reason: 'sum paid == total ${e.id}$why',
      );
      expect(
        m.owed.values.fold(0, (a, b) => a + b),
        m.total,
        reason: 'sum owed == total ${e.id}$why',
      );
    }
    // The suggested transfers (whatever the toggle) settle every net exactly.
    final transfers = p.transfers(g.groupId);
    expect(
      transfers,
      BalanceCalculator.suggestedTransfers(g),
      reason: 'groupTransfersProvider == core$why',
    );
    _expectSettles(nets, transfers, why);
    _expectSettles(nets, BalanceCalculator.pairwiseDebts(g), '$why pairwise');
    for (final c in nets.keys) {
      final simplified = DebtSimplifier.simplify(nets[c]!, c);
      _expectSettles({c: nets[c]!}, simplified, '$why simplified');
      expect(
        simplified.length,
        lessThanOrEqualTo(nets[c]!.length - 1),
        reason: 'simplify gives <= n-1 transfers$why',
      );
    }
    for (final t in transfers) {
      expect(t.amount, greaterThan(0), reason: 'transfer amounts > 0$why');
      expect(t.from, isNot(t.to), reason: 'no self transfer$why');
    }
    Summaries.myNetInGroup(g, p.me).forEach((c, v) {
      myNetSum[c] = (myNetSum[c] ?? 0) + v;
    });
  }
  myNetSum.removeWhere((_, v) => v == 0);
  final overall = p.overall();
  expect(
    overall.net,
    myNetSum,
    reason: 'overall.net == sum of myNetInGroup per currency$why',
  );
  final fromPeople = <String, int>{};
  for (final person in p.people()) {
    person.net.forEach((c, v) => fromPeople[c] = (fromPeople[c] ?? 0) + v);
  }
  fromPeople.removeWhere((_, v) => v == 0);
  expect(fromPeople, overall.net, reason: 'sum of people == overall$why');
  for (final c in {...overall.owedToMe.keys, ...overall.iOwe.keys}) {
    expect(
      (overall.owedToMe[c] ?? 0) - (overall.iOwe[c] ?? 0),
      overall.net[c] ?? 0,
      reason: 'owedToMe - iOwe == net for $c$why',
    );
  }
}

void _expectSettles(NetsByCurrency nets, List<Transfer> transfers, String why) {
  final left = {for (final c in nets.keys) c: Map<MemberId, int>.of(nets[c]!)};
  for (final t in transfers) {
    final cur = left.putIfAbsent(t.currency, () => {});
    cur[t.from] = (cur[t.from] ?? 0) + t.amount;
    cur[t.to] = (cur[t.to] ?? 0) - t.amount;
  }
  left.forEach((c, byMember) {
    expect(
      byMember.values.where((v) => v != 0),
      isEmpty,
      reason: 'transfers settle $c exactly$why: $transfers vs $nets',
    );
  });
}

/// Equal split helper.
SplitSpec eq(Iterable<MemberId> ms) => SplitSpec.equal(ms);
SplitSpec one(MemberId m, int total) => SplitSpec.single(m, total);
SplitSpec spec(SplitMethod method, Map<MemberId, int> v) =>
    SplitSpec(method, v);

/// Gives [to] the key of [g] held by [from] (as an invite would).
Future<void> shareGroup(QaPhone from, QaPhone to, GroupId g) async {
  final key = (await from.ledger.groupKeys())[g]!;
  await to.ledger.registerJoinedGroup(g, key, 'Trip');
}

/// One-way pull of everything [from] has for [g] that [to] lacks.
Future<void> pull(QaPhone from, QaPhone to, GroupId g) async {
  final missing = await from.ledger.opsMissingFor(
    g,
    await to.ledger.versionVector(g),
  );
  await to.ledger.applyRemote(g, missing);
  await pumpEventQueue();
}

/// Both ways.
Future<void> syncBoth(QaPhone x, QaPhone y, GroupId g) async {
  await pull(x, y, g);
  await pull(y, x, g);
}
