// Settle up (render 4): the tether hero with the amount riding on the line,
// how it was paid, what changes, then Record. Recording plays the dot
// travelling from payer to receiver before the screen closes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/balances.dart';
import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../data/repositories.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../format/money_format.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/kit_strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

class SettleScreen extends ConsumerStatefulWidget {
  const SettleScreen({
    super.key,
    required this.groupId,
    this.from,
    this.to,
    this.currency,
  });

  final GroupId groupId;
  final MemberId? from;
  final MemberId? to;

  /// The currency of the payment the user picked (SPEC 6.6: a payment
  /// settles only its own currency). Null: the pair's only debt, or a pick.
  final String? currency;

  @override
  ConsumerState<SettleScreen> createState() => _SettleScreenState();
}

class _SettleScreenState extends ConsumerState<SettleScreen> {
  MemberId? _from;
  MemberId? _to;
  String? _currency;
  int? _amount;
  PaymentMethod? _method;
  DateTime? _date;
  String _note = '';
  bool _recorded = false;
  bool _saving = false;
  ExpenseId? _recordedId;

  // Frozen at record time: the ledger moves on, the screen should not.
  int? _frozenOwed;
  List<BeforeAfterEntry>? _frozenEntries;

  @override
  void initState() {
    super.initState();
    _from = widget.from;
    _to = widget.to;
    _currency = widget.currency;
  }

  /// The suggested payment from [from] to [to] in [currency] (null if none).
  static Transfer? _transfer(
    List<Transfer> transfers,
    MemberId from,
    MemberId to,
    String currency,
  ) {
    for (final t in transfers) {
      if (t.from == from && t.to == to && t.currency == currency) return t;
    }
    return null;
  }

  void _pick(Transfer t) => setState(() {
    _from = t.from;
    _to = t.to;
    _currency = t.currency;
    _amount = null;
  });

  Future<void> _payPart(String currency, int max) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) =>
          _PartSheet(currency: currency, initial: _amount ?? max),
    );
    if (picked != null && picked > 0 && mounted) {
      setState(() => _amount = picked);
    }
  }

  Future<void> _record(
    GroupState g,
    String currency,
    int amount,
    PaymentMethod method,
    DateTime date,
    bool settlesFully,
    int owed,
    List<BeforeAfterEntry> entries,
  ) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _amount = amount;
      _frozenOwed = owed;
      _frozenEntries = entries;
    });
    final ledger = ref.read(ledgerRepositoryProvider);
    ExpenseId? id;
    final ok = await runGuarded(context, () async {
      id = await ledger.recordPayment(
        PaymentDraft(
          groupId: g.groupId,
          from: _from!,
          to: _to!,
          amount: amount,
          currency: currency,
          method: method,
          date: date.toUtc(),
          notes: _note,
        ),
      );
    });
    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      return;
    }
    if (settlesFully) {
      Haptics.heavy(context);
    } else {
      Haptics.medium(context);
    }
    setState(() {
      _recorded = true;
      _recordedId = id;
    });
  }

  void _close() {
    final id = _recordedId;
    final ledger = ref.read(ledgerRepositoryProvider);
    showSnack(
      context,
      S.paymentRecorded,
      actionLabel: id == null ? null : S.undo,
      onAction: id == null
          ? null
          : () => ledger.deleteExpense(id, groupId: widget.groupId),
    );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.group(widget.groupId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(groupProvider(widget.groupId)).value;
    final profile = ref.watch(profileProvider).value;
    final people = ref.watch(peopleBalancesProvider).value ?? const [];
    final overall = ref.watch(overallBalanceProvider).value;
    final now = ref.watch(clockProvider)();
    if (g == null || g.group == null || profile == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(close: true),
          title: const Text(S.settleTitle),
        ),
        body: const SizedBox.shrink(),
      );
    }
    final me = profile.personId;
    final myId = myMemberIn(g, me);
    final full = memberFullNames(g);
    final groupName = groupTitle(g, me);
    final transfers = BalanceCalculator.suggestedTransfers(g);

    // Without an explicit pair: yours if there is exactly one, else a list.
    if (_from == null || _to == null) {
      final mine = [
        for (final t in transfers)
          if (t.from == myId || t.to == myId) t,
      ];
      if (mine.length == 1 && !_recorded) {
        _from = mine.first.from;
        _to = mine.first.to;
        _currency = mine.first.currency;
      } else {
        return _PickPayment(
          group: g,
          groupName: groupName,
          transfers: [...mine, ...transfers.where((t) => !mine.contains(t))],
          myId: myId,
          full: full,
          onPick: _pick,
        );
      }
    }

    // A pair but no currency: the pair's only debt, or let the user pick
    // when the two owe each other in more than one currency.
    if (_currency == null) {
      final pair = [
        for (final t in transfers)
          if ((t.from == _from && t.to == _to) ||
              (t.from == _to && t.to == _from))
            t,
      ];
      if (pair.length > 1 && !_recorded) {
        return _PickPayment(
          group: g,
          groupName: groupName,
          transfers: pair,
          myId: myId,
          full: full,
          onPick: _pick,
        );
      }
      if (pair.length == 1) {
        _from = pair.first.from;
        _to = pair.first.to;
        _currency = pair.first.currency;
      }
    }

    final from = _from!;
    final to = _to!;
    final currency = _currency ?? g.group!.currency;
    final suggested = _transfer(transfers, from, to, currency);
    final owed = _frozenOwed ?? suggested?.amount ?? 0;
    final amount = _amount ?? (owed > 0 ? owed : 0);
    final method =
        _method ?? (currency == 'INR' ? PaymentMethod.upi : PaymentMethod.cash);
    final date = _date ?? now;
    final fromIsMe = from == myId;
    final toIsMe = to == myId;
    final fromName = full[from] ?? S.someone;
    final toName = full[to] ?? S.someone;
    final question = fromIsMe
        ? S.youPay(firstName(toName))
        : toIsMe
        ? S.paysYou(firstName(fromName))
        : S.pays(firstName(fromName), firstName(toName));
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;

    // What changes.
    final entries = <BeforeAfterEntry>[];
    if (fromIsMe || toIsMe) {
      final other = fromIsMe ? to : from;
      final otherFirst = firstName(fromIsMe ? toName : fromName);
      final delta = fromIsMe ? amount : -amount;
      final pairNow = _pairNet(transfers, myId!, other, currency);
      entries.add(
        BeforeAfterEntry(
          title: S.youAnd(otherFirst),
          subtitle: groupName,
          now: _personCell(pairNow),
          after: _personCell(pairNow + delta),
        ),
      );
      final otherPerson = g.members[other]?.personId;
      final pb = people.where((p) => p.personId == otherPerson);
      if (pb.isNotEmpty) {
        final pNow = pb.first.net[currency] ?? 0;
        entries.add(
          BeforeAfterEntry(
            title: S.overallOf(otherFirst),
            subtitle: S.allGroups,
            now: _personCell(pNow),
            after: _personCell(pNow + delta),
          ),
        );
      }
      final oNow = overall?.net[currency] ?? 0;
      entries.add(
        BeforeAfterEntry(
          title: S.yourOverall,
          now: _overallCell(oNow),
          after: _overallCell(oNow + delta),
        ),
      );
    } else {
      entries.add(
        BeforeAfterEntry(
          title: '${firstName(fromName)} and ${firstName(toName)}',
          subtitle: groupName,
          now: BalanceCell(
            word: owed == 0 ? KitStrings.settled : KitStrings.owes,
            minor: owed,
            direction: owed == 0
                ? MoneyDirection.settled
                : MoneyDirection.neutral,
          ),
          after: BalanceCell(
            word: owed - amount == 0 ? KitStrings.settled : KitStrings.owes,
            minor: (owed - amount).abs(),
            direction: owed - amount == 0
                ? MoneyDirection.settled
                : MoneyDirection.neutral,
          ),
        ),
      );
    }

    final amountText = MoneyFormat.format(amount, currency);
    final over = owed > 0 && amount > owed;
    return Scaffold(
      appBar: screenAppBar(
        leading: BackArrow(close: true, onPressed: _recorded ? _close : null),
        title: AppBarTitle(S.settleTitle, subtitle: groupName),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: FilledButton(
            onPressed: amount > 0 && !_saving && !_recorded
                ? () => _record(
                    g,
                    currency,
                    amount,
                    method,
                    date,
                    amount == owed,
                    owed,
                    entries,
                  )
                : null,
            style: KitButtonStyles.block,
            child: Text(S.recordPayment(amountText)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.lg),
        children: [
          const SizedBox(height: Space.sm),
          textGutter(
            SettleTether(
              fromId: from,
              fromName: fromName,
              toId: to,
              toName: toName,
              fromLabel: fromIsMe ? S.you : fromName,
              toLabel: toIsMe ? S.you : toName,
              amountMinor: amount,
              currency: currency,
              fromIsMe: fromIsMe,
              toIsMe: toIsMe,
              question: question,
              recorded: _recorded,
              onRecordedAnimationEnd: _close,
              action: TextLink(
                owed > 0 && amount == owed ? S.payPartOfIt : S.changeAmount,
                onPressed: _recorded ? null : () => _payPart(currency, owed),
              ),
            ),
          ),
          if (over)
            textGutter(
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  S.overpay(
                    MoneyFormat.format(amount - owed, currency),
                    firstName(toIsMe ? fromName : toName),
                  ),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall!.copyWith(color: ink2),
                ),
              ),
            ),
          gutter(
            SectionHeading(
              fromIsMe || !toIsMe ? S.howYouPaid : S.howTheyPaid,
              padding: const EdgeInsets.fromLTRB(4, 16, 4, Space.sectionBottom),
            ),
          ),
          gutter(
            PaymentMethodSelector(
              value: method,
              onChanged: (m) => setState(() => _method = m),
            ),
          ),
          textGutter(
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                S.methodNote(method.name),
                style: theme.textTheme.bodySmall!.copyWith(color: ink2),
              ),
            ),
          ),
          gutter(
            const SectionHeading(
              S.whatChanges,
              padding: EdgeInsets.fromLTRB(4, 20, 4, Space.sectionBottom),
            ),
          ),
          gutter(
            AnimatedSwitcher(
              duration: Motion.crossfade,
              child: BeforeAfterTable(
                key: ValueKey(_recorded),
                currency: currency,
                entries: _recorded
                    ? [
                        for (final e in _frozenEntries ?? entries)
                          BeforeAfterEntry(
                            title: e.title,
                            subtitle: e.subtitle,
                            now: e.after,
                            after: e.after,
                          ),
                      ]
                    : entries,
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            ListSection(
              children: [
                KeyValueRow(
                  label: S.date,
                  value: DateLabels.pickerDate(date, now: now),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(now.year + 1, 12, 31),
                    );
                    if (d != null) {
                      setState(
                        () => _date = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          now.hour,
                          now.minute,
                        ),
                      );
                    }
                  },
                ),
                KeyValueRow(
                  label: S.notes,
                  value: _note.isEmpty ? null : _note,
                  placeholder: S.optional,
                  onTap: () async {
                    final t = await promptText(
                      context,
                      title: S.notes,
                      initial: _note,
                    );
                    if (t != null) setState(() => _note = t);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static int _pairNet(
    List<Transfer> transfers,
    MemberId me,
    MemberId other,
    String currency,
  ) {
    var net = 0;
    for (final t in transfers) {
      if (t.currency != currency) continue;
      if (t.from == me && t.to == other) net -= t.amount;
      if (t.to == me && t.from == other) net += t.amount;
    }
    return net;
  }

  static BalanceCell _personCell(int v) => BalanceCell(
    word: v > 0
        ? KitStrings.owesYou
        : v < 0
        ? KitStrings.youOwe
        : KitStrings.settled,
    minor: v,
  );

  static BalanceCell _overallCell(int v) => BalanceCell(
    word: v > 0
        ? KitStrings.youreOwed
        : v < 0
        ? KitStrings.youOwe
        : KitStrings.settled,
    minor: v,
  );
}

/// "Who is paying?": every suggested payment, yours first.
class _PickPayment extends StatelessWidget {
  const _PickPayment({
    required this.group,
    required this.groupName,
    required this.transfers,
    required this.myId,
    required this.full,
    required this.onPick,
  });

  final GroupState group;
  final String groupName;
  final List<Transfer> transfers;
  final MemberId? myId;
  final Map<MemberId, String> full;
  final ValueChanged<Transfer> onPick;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: screenAppBar(
      leading: const BackArrow(close: true),
      title: AppBarTitle(S.settleTitle, subtitle: groupName),
    ),
    body: transfers.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(Space.xl),
              child: EmptyState(
                headline: S.nothingToSettle,
                body: S.nothingToSettleBody,
              ),
            ),
          )
        : ListView(
            children: [
              gutter(
                ListSection(
                  title: S.whoIsPaying,
                  children: [
                    for (final t in transfers)
                      TransferRow(
                        fromId: t.from,
                        fromName: full[t.from] ?? S.someone,
                        toId: t.to,
                        toName: full[t.to] ?? S.someone,
                        amountMinor: t.amount,
                        currency: t.currency,
                        fromIsMe: t.from == myId,
                        toIsMe: t.to == myId,
                        onTap: () => onPick(t),
                      ),
                  ],
                ),
              ),
            ],
          ),
  );
}

/// "Pay part of it": a smaller (or larger) amount.
class _PartSheet extends StatefulWidget {
  const _PartSheet({required this.currency, required this.initial});

  final String currency;
  final int initial;

  @override
  State<_PartSheet> createState() => _PartSheetState();
}

class _PartSheetState extends State<_PartSheet> {
  late int? _value = widget.initial;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.text, 0, Space.text, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(S.partTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Space.md),
            AmountField(
              currency: widget.currency,
              initialMinor: widget.initial,
              autofocus: true,
              onChanged: (v) => setState(() => _value = v),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: (_value ?? 0) > 0
                  ? () => Navigator.of(context).pop(_value)
                  : null,
              style: KitButtonStyles.block,
              child: const Text(S.done),
            ),
          ],
        ),
      ),
    ),
  );
}
