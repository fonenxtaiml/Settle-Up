// Settle up (render 4): the tether hero with the amount riding on the line,
// how it was paid, what changes, then Record. Recording plays the dot
// travelling from payer to receiver before the screen closes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'settle_preview.dart';

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
  bool _closed = false;
  ExpenseId? _recordedId;

  // Frozen while the payment is saved and once it is recorded: the ledger
  // moves on, the screen should not. All of it or none of it: a save that
  // fails thaws it, so the screen follows the amount again (MONEY-R26-02).
  // It holds everything the payment is built from (amount, method, date,
  // note), the screen shows those, and every control that sets them is
  // locked meanwhile, so what is shown is what is stored (MONEY-R27-01).
  _Frozen? _frozen;

  /// Nothing the payment is built from can change: it is being saved or
  /// has been recorded.
  bool get _locked => _saving || _recorded;

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
    if (picked != null && picked > 0 && mounted && !_locked) {
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
    String? overpay,
  ) async {
    if (_locked) return;
    final frozen = (
      owed: owed,
      entries: entries,
      overpay: overpay,
      method: method,
      date: date,
      note: _note,
    );
    final draft = PaymentDraft(
      groupId: g.groupId,
      from: _from!,
      to: _to!,
      amount: amount,
      currency: currency,
      method: frozen.method,
      date: frozen.date.toUtc(),
      notes: frozen.note,
    );
    setState(() {
      _saving = true;
      _amount = amount;
      _frozen = frozen;
    });
    final ledger = ref.read(ledgerRepositoryProvider);
    ExpenseId? id;
    final ok = await runGuarded(context, () async {
      id = await ledger.recordPayment(draft);
    });
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _saving = false;
        _frozen = null;
      });
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

  /// Once, by the end of the recorded animation or the close button,
  /// whichever comes first: closes Settle up itself, never a pop-up over
  /// it or the screen under it (MONEY-R27-01).
  void _close() {
    if (_closed) return;
    _closed = true;
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
    closeScreen(context, fallback: Routes.group(widget.groupId));
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(groupProvider(widget.groupId)).value;
    final profile = ref.watch(profileProvider).value;
    final state = ref.watch(ledgerProvider).value?.state ?? LedgerState.empty;
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
    final frozen = _frozen;
    final owed = frozen?.owed ?? suggested?.amount ?? 0;
    final amount = _amount ?? (owed > 0 ? owed : 0);
    final method =
        frozen?.method ??
        _method ??
        (currency == 'INR' ? PaymentMethod.upi : PaymentMethod.cash);
    final date = frozen?.date ?? _date ?? now;
    final note = frozen?.note ?? _note;
    final locked = _locked;
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

    // What changes: the balances the Group, Person and Friends screens
    // will show once the payment is recorded, from the same calculation
    // run on the group with the payment applied (MONEY-R24-01). The
    // suggested payments are recomputed from the new nets and can route
    // the debts differently, so "now + amount" is not what they show.
    final preview = SettlePreview.of(
      state,
      me,
      groupId: g.groupId,
      from: from,
      to: to,
      amount: amount,
      currency: currency,
      date: date,
    );
    final entries = <BeforeAfterEntry>[];
    if (fromIsMe || toIsMe) {
      final other = fromIsMe ? to : from;
      final otherFirst = firstName(fromIsMe ? toName : fromName);
      entries.add(
        BeforeAfterEntry(
          title: S.youAnd(otherFirst),
          subtitle: groupName,
          now: _personCell(preview.pairNow(myId!, other)),
          after: _personCell(preview.pairAfter(myId, other)),
        ),
      );
      final otherPerson = g.members[other]?.personId;
      final pNow = otherPerson == null ? null : preview.personNow(otherPerson);
      final pAfter = otherPerson == null
          ? null
          : preview.personAfter(otherPerson);
      if (pNow != null && pAfter != null) {
        entries.add(
          BeforeAfterEntry(
            title: S.overallOf(otherFirst),
            subtitle: S.allGroups,
            now: _personCell(pNow),
            after: _personCell(pAfter),
          ),
        );
      }
    } else {
      entries.add(
        BeforeAfterEntry(
          title: '${firstName(fromName)} and ${firstName(toName)}',
          subtitle: groupName,
          now: _thirdPartyCell(preview.pairNow(from, to), toName),
          after: _thirdPartyCell(preview.pairAfter(from, to), toName),
        ),
      );
    }
    // Everyone else whose balance with me the payment moves: all but the
    // person already in the "You and X" row above. A payment between two
    // others can move my balances too, with either of them or with someone
    // else, when the debts are routed again (MONEY-R26-01).
    if (myId != null) {
      final shown = {if (fromIsMe) to, if (toIsMe) from};
      for (final m in preview.othersChanged(myId, shown)) {
        entries.add(
          BeforeAfterEntry(
            title: S.youAnd(firstName(full[m] ?? S.someone)),
            subtitle: groupName,
            now: _personCell(preview.pairNow(myId, m)),
            after: _personCell(preview.pairAfter(myId, m)),
          ),
        );
      }
    }
    if (fromIsMe || toIsMe) {
      entries.add(
        BeforeAfterEntry(
          title: S.yourOverall,
          now: _overallCell(preview.overallNow),
          after: _overallCell(preview.overallAfter),
        ),
      );
    }

    final amountText = MoneyFormat.format(amount, currency);
    final over = owed > 0 && amount > owed;
    // Over the balance: who owes whom the extra once it is recorded, as
    // the ledger will show it (the extra can close a cycle or reroute
    // through someone else, and then nobody owes it back).
    final overText = frozen != null
        ? frozen.overpay
        : (over
              ? _overpayText(
                  amount - owed,
                  currency,
                  back: preview.pairAfter(from, to),
                  fromName: fromIsMe ? null : firstName(fromName),
                  toName: toIsMe ? null : firstName(toName),
                )
              : null);
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
                    overText,
                  )
                : null,
            style: KitButtonStyles.block,
            child: Text(S.recordPayment(amountText)),
          ),
        ),
      ),
      body: InputLock(
        locked: locked,
        child: ListView(
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
                  onPressed: locked ? null : () => _payPart(currency, owed),
                ),
              ),
            ),
            if (overText != null)
              textGutter(
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    overText,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall!.copyWith(color: ink2),
                  ),
                ),
              ),
            gutter(
              SectionHeading(
                fromIsMe || !toIsMe ? S.howYouPaid : S.howTheyPaid,
                padding: const EdgeInsets.fromLTRB(
                  4,
                  16,
                  4,
                  Space.sectionBottom,
                ),
              ),
            ),
            gutter(
              PaymentMethodSelector(
                value: method,
                onChanged: locked ? null : (m) => setState(() => _method = m),
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
                          for (final e in frozen?.entries ?? entries)
                            BeforeAfterEntry(
                              title: e.title,
                              subtitle: e.subtitle,
                              now: e.after,
                              after: e.after,
                            ),
                        ]
                      : frozen?.entries ?? entries,
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
                    onTap: locked
                        ? null
                        : () async {
                            final d = await pickEntryDate(
                              context,
                              initial: date,
                              now: now,
                            );
                            if (d != null && mounted && !_locked) {
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
                    value: note.isEmpty ? null : note,
                    placeholder: S.optional,
                    onTap: locked
                        ? null
                        : () async {
                            final t = await promptText(
                              context,
                              title: S.notes,
                              initial: _note,
                              maxLength: kNotesMax,
                              optional: true,
                              multiline: true,
                            );
                            if (t != null && mounted && !_locked) {
                              setState(() => _note = t);
                            }
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The pair cell of a payment between two other people, from the
  /// payer's side: [v] < 0 the payer still owes, > 0 the one paid
  /// ([toName]) owes the payer now.
  static BalanceCell _thirdPartyCell(int v, String toName) => BalanceCell(
    word: v == 0
        ? KitStrings.settled
        : v < 0
        ? KitStrings.owes
        : S.nameOwes(firstName(toName)),
    minor: v.abs(),
    direction: v == 0 ? MoneyDirection.settled : MoneyDirection.neutral,
  );

  /// "That's ₹10 more than the balance." and, when the one paid then owes
  /// the payer [back] (> 0), who owes whom: "Sam will owe you ₹10." Null
  /// names stand for me.
  static String _overpayText(
    int extra,
    String currency, {
    required int back,
    required String? fromName,
    required String? toName,
  }) {
    final first = S.overpay(MoneyFormat.format(extra, currency));
    if (back <= 0) return first;
    return '$first ${S.willOwe(toName, fromName, MoneyFormat.format(back, currency))}';
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

/// What Settle up shows for the payment being saved or just recorded.
typedef _Frozen = ({
  int owed,
  List<BeforeAfterEntry> entries,
  String? overpay,
  PaymentMethod method,
  DateTime date,
  String note,
});

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
