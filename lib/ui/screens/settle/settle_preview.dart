// What Settle up shows under "What changes": the balances the Group,
// Person and Friends screens will show once the payment is recorded.
//
// The suggested payments are recomputed from the new nets (DebtSimplifier
// with simplify on, cancelCycles over the pairwise debts with it off), so
// a payment can route the debts differently: paying Sam part of what I owe
// him can move what I owe Priya, and paying more than a balance can close
// a cycle instead of leaving the extra with the person paid. Adding the
// amount to the balance as it is now cannot predict that (MONEY-R24-01).
// The preview runs the same calculation the screens run, on the group with
// the draft payment applied.
import '../../../core/balances.dart';
import '../../../core/categories.dart';
import '../../../core/hlc.dart';
import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';

/// The balances before and after a draft payment in one group.
final class SettlePreview {
  SettlePreview._({
    required this.currency,
    required this.transfersNow,
    required this.transfersAfter,
    required this.peopleNow,
    required this.peopleAfter,
  });

  /// The preview of [from] paying [to] [amount] of [currency] in
  /// [groupId], as [me] sees it. An [amount] of 0 or less changes nothing.
  factory SettlePreview.of(
    LedgerState state,
    PersonId me, {
    required GroupId groupId,
    required MemberId from,
    required MemberId to,
    required int amount,
    required String currency,
    required DateTime date,
  }) {
    final g = state.groups[groupId];
    final after = g == null || amount <= 0
        ? state
        : withPayment(
            state,
            g,
            from: from,
            to: to,
            amount: amount,
            currency: currency,
            date: date,
          );
    final gAfter = after.groups[groupId];
    return SettlePreview._(
      currency: currency,
      transfersNow: g == null
          ? const []
          : BalanceCalculator.suggestedTransfers(g),
      transfersAfter: gAfter == null
          ? const []
          : BalanceCalculator.suggestedTransfers(gAfter),
      peopleNow: Summaries.people(state, me),
      peopleAfter: identical(after, state)
          ? Summaries.people(state, me)
          : Summaries.people(after, me),
    );
  }

  /// Id of the draft payment in the state [withPayment] returns. Not an
  /// id format the Ledger writes, so it never meets a stored expense.
  static const ExpenseId draftId = '~draft-payment';

  /// [state] with the payment of [amount] from [from] to [to] added to
  /// [group], as the Ledger stores a recorded payment.
  static LedgerState withPayment(
    LedgerState state,
    GroupState group, {
    required MemberId from,
    required MemberId to,
    required int amount,
    required String currency,
    required DateTime date,
  }) {
    final payment = Expense(
      id: draftId,
      groupId: group.groupId,
      kind: ExpenseKind.payment,
      description: '',
      category: Categories.payment,
      date: date,
      notes: '',
      money: MoneyBlock(
        total: amount,
        currency: currency,
        paidBy: SplitSpec(SplitMethod.exact, {from: amount}),
        owedBy: SplitSpec(SplitMethod.exact, {to: amount}),
        paid: {from: amount},
        owed: {to: amount},
      ),
      createdBy: from,
      createdAt: date,
      updatedHlc: Hlc(date.millisecondsSinceEpoch, 0, ''),
    );
    return LedgerState({
      ...state.groups,
      group.groupId: GroupState(
        groupId: group.groupId,
        group: group.group,
        members: group.members,
        expenses: {...group.expenses, draftId: payment},
      ),
    });
  }

  final String currency;

  /// The group's suggested payments now and once the payment is recorded.
  final List<Transfer> transfersNow;
  final List<Transfer> transfersAfter;

  /// Every person's balance with me (the Friends screen) now and after.
  final List<PersonBalance> peopleNow;
  final List<PersonBalance> peopleAfter;

  /// What [b] owes [a] in the group in [currency] (negative: [a] owes
  /// [b]), as the Group screen shows it: from the suggested payments.
  static int pairNet(
    List<Transfer> transfers,
    MemberId a,
    MemberId b,
    String currency,
  ) {
    var net = 0;
    for (final t in transfers) {
      if (t.currency != currency) continue;
      if (t.from == a && t.to == b) net -= t.amount;
      if (t.to == a && t.from == b) net += t.amount;
    }
    return net;
  }

  int pairNow(MemberId a, MemberId b) => pairNet(transfersNow, a, b, currency);
  int pairAfter(MemberId a, MemberId b) =>
      pairNet(transfersAfter, a, b, currency);

  /// Members of the group, other than [me] and [except], whose balance
  /// with [me] the payment changes, in id order.
  List<MemberId> othersChanged(MemberId me, Set<MemberId> except) {
    final ids = <MemberId>{
      for (final t in [...transfersNow, ...transfersAfter])
        if (t.currency == currency) ...[t.from, t.to],
    }..removeAll({me, ...except});
    return [
      for (final m in ids.toList()..sort())
        if (pairNow(me, m) != pairAfter(me, m)) m,
    ];
  }

  /// What [person] owes me across all groups (negative: I owe them), as
  /// the Friends screen shows it; null when they share no group with me.
  int? personNow(PersonId person) => _personNet(peopleNow, person);
  int? personAfter(PersonId person) => _personNet(peopleAfter, person);

  int? _personNet(List<PersonBalance> people, PersonId person) {
    for (final p in people) {
      if (p.personId == person) return p.net[currency] ?? 0;
    }
    return null;
  }

  /// My overall balance in [currency], as the Friends screen sums it.
  int get overallNow => _overall(peopleNow);
  int get overallAfter => _overall(peopleAfter);

  int _overall(List<PersonBalance> people) =>
      people.fold(0, (a, p) => a + (p.net[currency] ?? 0));
}
