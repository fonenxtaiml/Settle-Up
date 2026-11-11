// Edit a recorded payment: amount, how it was paid, date and note.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models.dart';
import '../../../data/repositories.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../format/money_format.dart';
import '../../providers.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

class PaymentEditScreen extends ConsumerStatefulWidget {
  const PaymentEditScreen({super.key, required this.expense});

  final Expense expense;

  @override
  ConsumerState<PaymentEditScreen> createState() => _PaymentEditScreenState();
}

class _PaymentEditScreenState extends ConsumerState<PaymentEditScreen> {
  late int? _amount = widget.expense.money.total;
  late PaymentMethod _method = _loadedMethod;
  late DateTime _date = _loadedDate;
  late final _notes = TextEditingController(text: widget.expense.notes);

  // What the form loaded: Save compares with these, not with the live
  // payment (UIFLOW-R17-01).
  late final PaymentMethod _loadedMethod =
      widget.expense.paymentMethod ?? PaymentMethod.cash;
  late final DateTime _loadedDate = widget.expense.date.toLocal();
  late final String _loadedNotes = widget.expense.notes.trim();
  bool _saving = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = _amount ?? 0;
    if (amount <= 0 || _saving) return;
    setState(() => _saving = true);
    final e = widget.expense;
    final ledger = ref.read(ledgerRepositoryProvider);
    // A field still holding what the form loaded takes the live value, so
    // a change another phone made to it while the form was open is not
    // undone (UIFLOW-R17-01). The amount, the people and the currency are
    // the payment's money, one field.
    final live = ledger.current.state.expenseIn(e.groupId, e.id) ?? e;
    final notes = _notes.text.trim();
    final moneyKept = amount == e.money.total;
    final money = moneyKept ? live : e;
    final ok = await runGuarded(
      context,
      () => ledger.updatePayment(
        e.id,
        PaymentDraft(
          groupId: e.groupId,
          from: money.payer,
          to: money.receiver,
          amount: moneyKept ? live.money.total : amount,
          currency: money.money.currency,
          method: _method == _loadedMethod
              ? (live.paymentMethod ?? _method)
              : _method,
          date: _date == _loadedDate ? live.date : _date.toUtc(),
          notes: notes == _loadedNotes ? live.notes : notes,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    Haptics.medium(context);
    showSnack(context, S.expenseSaved);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.expense;
    final g = ref.watch(groupProvider(e.groupId)).value;
    final me = ref.watch(profileProvider).value?.personId;
    final full = g == null ? const <String, String>{} : memberFullNames(g);
    final myId = g == null || me == null ? null : myMemberIn(g, me);
    final now = ref.watch(clockProvider)();
    final currency = e.money.currency;
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: const Text(S.paymentTitle),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: FilledButton(
            onPressed: (_amount ?? 0) > 0 && !_saving ? _save : null,
            style: KitButtonStyles.block,
            child: const Text(S.saveChanges),
          ),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: Space.sm),
          gutter(
            TetherTransfer(
              fromId: e.payer,
              fromName: full[e.payer] ?? S.someone,
              toId: e.receiver,
              toName: full[e.receiver] ?? S.someone,
              fromIsMe: e.payer == myId,
              toIsMe: e.receiver == myId,
              line: TetherLine.solid,
            ),
          ),
          const SizedBox(height: Space.lg),
          textGutter(
            AmountField(
              currency: currency,
              initialMinor: e.money.total,
              onChanged: (v) => setState(() => _amount = v),
            ),
          ),
          gutter(const SectionHeading(S.howYouPaid)),
          gutter(
            PaymentMethodSelector(
              value: _method,
              onChanged: (m) => setState(() => _method = m),
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            ListSection(
              children: [
                KeyValueRow(
                  label: S.date,
                  value: DateLabels.pickerDate(_date, now: now),
                  onTap: () async {
                    final d = await pickEntryDate(
                      context,
                      initial: _date,
                      now: now,
                    );
                    if (d != null) {
                      setState(
                        () => _date = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          _date.hour,
                          _date.minute,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            LabeledTextField(
              label: S.notes,
              hintText: S.notesHint,
              controller: _notes,
              multiline: true,
              inputFormatters: notesFormatters(),
              errorText: notesInputError(_notes.text),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: Space.sm),
          textGutter(
            Text(
              MoneyFormat.format(e.money.total, currency),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
