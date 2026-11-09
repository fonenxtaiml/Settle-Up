// Shared builders for core tests: a simulated device that authors ops with
// its own HLC clock and per-group counters, like the data layer's Ledger.
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';

/// 2026-11-09T00:00:00Z
const int kBaseMs = 1794182400000;

final class FakeDevice {
  FakeDevice(this.deviceId, {this.skewMs = 0, int Function()? now}) {
    clock = HlcClock(
      deviceId: deviceId,
      nowMillis: now ?? () => wallMs + skewMs,
    );
  }

  final DeviceId deviceId;

  /// How far this device's wall clock is off true time.
  final int skewMs;
  late final HlcClock clock;

  /// Shared simulated wall clock (true time); devices add their own skew.
  static int wallMs = kBaseMs;

  final Map<GroupId, int> _counters = {};

  /// Simulates receiving [ops] from a peer: merges their max HLC.
  void saw(Iterable<Operation> ops) {
    Hlc? max;
    for (final op in ops) {
      if (max == null || op.hlc > max) max = op.hlc;
    }
    if (max != null) clock.receive(max);
  }

  int _opSeq = 0;

  Operation op(
    GroupId groupId,
    EntityType type,
    String entityId,
    OpKind kind,
    Map<String, Object?> payload, {
    Hlc? hlc,
  }) {
    final counter = (_counters[groupId] ?? 0) + 1;
    _counters[groupId] = counter;
    return Operation(
      id: '$deviceId/op/${++_opSeq}',
      groupId: groupId,
      deviceId: deviceId,
      counter: counter,
      hlc: hlc ?? clock.tick(),
      entityType: type,
      entityId: entityId,
      kind: kind,
      payload: payload,
    );
  }

  Operation createGroup(
    GroupId g, {
    String name = 'Trip',
    GroupType type = GroupType.trip,
    String currency = 'GBP',
    bool simplify = true,
    int? createdAt,
    Map<String, Object?> extra = const {},
  }) =>
      op(g, EntityType.group, g, OpKind.create, {
        GroupFields.name: name,
        GroupFields.type: type.name,
        GroupFields.currency: currency,
        GroupFields.simplifyDebts: simplify,
        GroupFields.createdAt: createdAt ?? clock.last.millis,
        ...extra,
      });

  Operation updateGroup(GroupId g, Map<String, Object?> fields) =>
      op(g, EntityType.group, g, OpKind.update, fields);

  Operation addMember(
    GroupId g,
    MemberId m,
    String name, {
    PersonId? personId,
    DeviceId? claimedBy,
    int? createdAt,
  }) =>
      op(g, EntityType.member, m, OpKind.create, {
        MemberFields.displayName: name,
        MemberFields.personId: personId ?? 'person-$m',
        MemberFields.createdAt: createdAt ?? clock.last.millis,
        MemberFields.deviceId: ?claimedBy,
      });

  Operation updateMember(GroupId g, MemberId m, Map<String, Object?> fields) =>
      op(g, EntityType.member, m, OpKind.update, fields);

  Operation mergeMember(GroupId g, MemberId from, MemberId into) =>
      updateMember(g, from, {MemberFields.mergedInto: into});

  Operation removeMember(GroupId g, MemberId m) {
    final hlc = clock.tick();
    return op(g, EntityType.member, m, OpKind.delete,
        {MemberFields.deletedAt: hlc.millis},
        hlc: hlc);
  }

  Operation addExpense(
    GroupId g,
    ExpenseId e, {
    required MoneyBlock money,
    String description = 'Dinner',
    String category = 'food.dining',
    int? date,
    String? notes,
    MemberId createdBy = 'a',
    ExpenseKind kind = ExpenseKind.expense,
    PaymentMethod? method,
  }) {
    final hlc = clock.tick();
    return op(g, EntityType.expense, e, OpKind.create, {
      ExpenseFields.kind: kind.name,
      ExpenseFields.description: description,
      ExpenseFields.category: category,
      ExpenseFields.date: date ?? hlc.millis,
      ExpenseFields.money: money.toJson(),
      ExpenseFields.createdBy: createdBy,
      ExpenseFields.createdAt: hlc.millis,
      ExpenseFields.notes: ?notes,
      if (method != null) ExpenseFields.paymentMethod: method.name,
    }, hlc: hlc);
  }

  Operation addPayment(
    GroupId g,
    ExpenseId e, {
    required MemberId from,
    required MemberId to,
    required int amount,
    String currency = 'GBP',
    PaymentMethod method = PaymentMethod.cash,
  }) =>
      addExpense(
        g,
        e,
        money: SplitCalculator.paymentBlock(
            from: from, to: to, amount: amount, currency: currency),
        description: '',
        category: 'payment',
        createdBy: from,
        kind: ExpenseKind.payment,
        method: method,
      );

  Operation updateExpense(GroupId g, ExpenseId e, Map<String, Object?> f) =>
      op(g, EntityType.expense, e, OpKind.update, f);

  Operation editMoney(GroupId g, ExpenseId e, MoneyBlock money) =>
      updateExpense(g, e, {ExpenseFields.money: money.toJson()});

  Operation deleteExpense(GroupId g, ExpenseId e) {
    final hlc = clock.tick();
    return op(g, EntityType.expense, e, OpKind.delete,
        {ExpenseFields.deletedAt: hlc.millis},
        hlc: hlc);
  }

  Operation restoreExpense(GroupId g, ExpenseId e) => op(
      g, EntityType.expense, e, OpKind.restore, {ExpenseFields.deletedAt: null});
}

/// Equal split of [total] paid entirely by [payer].
MoneyBlock equalBlock(int total, MemberId payer, List<MemberId> owers,
        {String currency = 'GBP'}) =>
    SplitCalculator.buildMoneyBlock(
      total: total,
      currency: currency,
      paidBy: SplitSpec.single(payer, total),
      owedBy: SplitSpec.equal(owers),
    );

/// A reducer with [ops] applied in order.
LedgerReducer reduce(Iterable<Operation> ops) =>
    LedgerReducer()..applyAll(ops);

/// Builds a GroupState directly (for algorithm tests that do not need ops).
GroupState groupOf(
  List<Member> members,
  List<Expense> expenses, {
  bool simplify = false,
  GroupType type = GroupType.trip,
  GroupId id = 'g',
}) =>
    GroupState(
      groupId: id,
      group: Group(
        id: id,
        name: 'G',
        type: type,
        currency: 'GBP',
        simplifyDebts: simplify,
        createdAt: utcFromMillis(kBaseMs),
      ),
      members: {for (final m in members) m.id: m},
      expenses: {for (final e in expenses) e.id: e},
    );

Member member(
  MemberId id, {
  String? name,
  PersonId? personId,
  MemberId? mergedInto,
  bool removed = false,
  DeviceId? deviceId,
  int createdAt = kBaseMs,
  GroupId groupId = 'g',
}) =>
    Member(
      id: id,
      groupId: groupId,
      displayName: name ?? id.toUpperCase(),
      personId: personId ?? 'p-$id',
      createdAt: utcFromMillis(createdAt),
      deviceId: deviceId,
      mergedInto: mergedInto,
      deletedAt: removed ? utcFromMillis(createdAt + 1) : null,
    );

int _expenseSeq = 0;

Expense expense(
  MoneyBlock money, {
  ExpenseId? id,
  bool deleted = false,
  int date = kBaseMs,
  ExpenseKind kind = ExpenseKind.expense,
  String description = 'Dinner',
  String category = 'food.dining',
  GroupId groupId = 'g',
}) =>
    Expense(
      id: id ?? 'e${(++_expenseSeq).toString().padLeft(4, '0')}',
      groupId: groupId,
      kind: kind,
      description: description,
      category: category,
      date: utcFromMillis(date),
      notes: '',
      money: money,
      createdBy: money.paid.keys.first,
      createdAt: utcFromMillis(date),
      updatedHlc: Hlc(date, 0, 'dev'),
      deletedAt: deleted ? utcFromMillis(date + 1) : null,
    );

/// Block with explicit paid/owed maps (no validation; for invalid cases).
MoneyBlock rawBlock(Map<MemberId, int> paid, Map<MemberId, int> owed,
    {String currency = 'GBP'}) {
  final total = paid.values.fold(0, (a, b) => a + b);
  return MoneyBlock(
    total: total,
    currency: currency,
    paidBy: SplitSpec(SplitMethod.exact, paid),
    owedBy: SplitSpec(SplitMethod.exact, owed),
    paid: paid,
    owed: owed,
  );
}
