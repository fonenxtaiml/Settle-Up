// Reference-screen compositions of the design-system widgets, matching
// docs/design/point-to-point/*.png (render 1 to 6). Used by the golden
// gallery and by the large-text overflow tests.
import 'package:flutter/material.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void _noop() {}

final DateTime galleryNow = DateTime(2026, 11, 9, 10);

/// Screen gutter for containers (16) and text (20).
Widget _g(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Space.screen),
  child: child,
);

Widget _t(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Space.text),
  child: child,
);

PreferredSizeWidget _appBar(
  BuildContext context, {
  required Widget title,
  Widget? leading,
  List<Widget> actions = const [],
}) => AppBar(
  leading: leading,
  titleSpacing: leading == null ? Space.text : 0,
  title: title,
  actions: [
    for (var i = 0; i < actions.length; i++) ...[
      if (i > 0) const SizedBox(width: Space.xs),
      actions[i],
    ],
  ],
);

/// Render 1 / 6: Home.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _appBar(
      context,
      title: const Text('Settle Up'),
      actions: [
        IconButton(
          onPressed: _noop,
          tooltip: 'Search expenses',
          icon: const Icon(Icons.search_rounded),
        ),
        IconButton(
          onPressed: _noop,
          tooltip: 'Your profile',
          icon: const PersonAvatar(
            id: 'me',
            name: 'Arjun Mehta',
            size: Sizes.avatarSmall,
            isMe: true,
          ),
        ),
      ],
    ),
    floatingActionButton: const AddExpenseFab(onPressed: _noop),
    bottomNavigationBar: AppNavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (_) {},
      pendingCount: 3,
    ),
    body: ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const SizedBox(height: Space.xs),
        _t(
          const BalanceHero(
            net: {'INR': 425000},
            owedToMe: {'INR': 509000},
            iOwe: {'INR': 84000},
            mainCurrency: 'INR',
          ),
        ),
        const SizedBox(height: Space.lg),
        _g(
          SyncBanner(
            state: SyncChipState.changesWaiting,
            pendingCount: 3,
            peerName: "Priya's Pixel 8",
            lastSyncedAt: galleryNow.subtract(const Duration(hours: 26)),
            now: galleryNow,
            onTap: _noop,
            onSync: _noop,
          ),
        ),
        _g(
          ListSection(
            title: 'Groups',
            titleAction: TextLink('See all', onPressed: _noop),
            children: const [
              BalanceRow(
                kind: BalanceRowKind.group,
                id: 'g-goa',
                title: 'Goa trip',
                subtitle: '6 people',
                net: {'INR': -84000},
                onTap: _noop,
              ),
              BalanceRow(
                kind: BalanceRowKind.group,
                id: 'g-flat',
                title: 'Flat 4B',
                subtitle: '3 people',
                net: {'INR': 509000},
                onTap: _noop,
              ),
              BalanceRow(
                kind: BalanceRowKind.group,
                id: 'g-cabin',
                title: 'Cabin weekend',
                subtitle: '4 people',
                net: {'INR': 0},
                onTap: _noop,
              ),
            ],
          ),
        ),
        _g(
          const ListSection(
            title: 'People',
            dividerIndent: Space.avatarRowInset,
            children: [
              BalanceRow(
                kind: BalanceRowKind.person,
                id: 'p-priya',
                title: 'Priya Sharma',
                subtitle: 'Goa trip, Flat 4B',
                net: {'INR': 120000},
                onTap: _noop,
              ),
              BalanceRow(
                kind: BalanceRowKind.person,
                id: 'p-ravi',
                title: 'Ravi Kumar',
                subtitle: 'Goa trip',
                net: {'INR': -96000},
                onTap: _noop,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Render 2: Group detail.
class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key});

  static const names = {
    'm-me': 'You',
    'm-priya': 'Priya',
    'm-ravi': 'Ravi',
    'm-kabir': 'Kabir',
    'm-isha': 'Isha',
    'm-neha': 'Neha',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _appBar(
      context,
      leading: IconButton(
        onPressed: _noop,
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const AppBarTitle('Goa trip', subtitle: '6 people, ₹38,400 spent'),
      actions: [
        IconButton(
          onPressed: _noop,
          tooltip: 'Invite to group',
          icon: const Icon(Icons.person_add_alt_rounded),
        ),
        IconButton(
          onPressed: _noop,
          tooltip: 'More options',
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ],
    ),
    floatingActionButton: const AddExpenseFab(onPressed: _noop),
    body: ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        _t(
          const GroupBalanceHero(
            minor: -84000,
            currency: 'INR',
            detail: 'You paid ₹6,000 and your share is ₹6,840.',
          ),
        ),
        const SizedBox(height: 14),
        _t(
          const Row(
            children: [
              Expanded(
                child: FilledButton(onPressed: _noop, child: Text('Settle up')),
              ),
              SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _noop,
                  child: Text('All balances'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _g(
          ListSection(
            header: SuggestedPaymentsHeader(
              simplify: true,
              onSimplifyChanged: (_) {},
            ),
            padding: const EdgeInsets.only(bottom: 4),
            children: const [
              TransferRow(
                fromId: 'm-me',
                fromName: 'Arjun Mehta',
                toId: 'm-priya',
                toName: 'Priya Sharma',
                amountMinor: 84000,
                currency: 'INR',
                fromIsMe: true,
                onTap: _noop,
              ),
              TransferRow(
                fromId: 'm-kabir',
                fromName: 'Kabir Singh',
                toId: 'm-ravi',
                toName: 'Ravi Kumar',
                amountMinor: 615000,
                currency: 'INR',
              ),
              TransferRow(
                fromId: 'm-isha',
                fromName: 'Isha Nair',
                toId: 'm-ravi',
                toName: 'Ravi Kumar',
                amountMinor: 401000,
                currency: 'INR',
              ),
            ],
          ),
        ),
        _g(
          ListSection(
            title: 'Expenses',
            padding: const EdgeInsets.only(bottom: 4),
            children: [
              const DateSubhead('Today'),
              ExpenseRow(
                expense: testExpense(
                  id: 'e-scooter',
                  description: 'Scooter rental',
                  category: 'transport',
                  paid: {'m-priya': 240000},
                  owed: {
                    'm-me': 60000,
                    'm-priya': 60000,
                    'm-ravi': 60000,
                    'm-neha': 60000,
                  },
                ),
                memberNames: names,
                myMemberId: 'm-me',
                onTap: _noop,
              ),
              ExpenseRow(
                expense: testExpense(
                  id: 'e-pay',
                  kind: ExpenseKind.payment,
                  paid: {'m-ravi': 200000},
                  owed: {'m-me': 200000},
                ),
                memberNames: names,
                myMemberId: 'm-me',
                onTap: _noop,
              ),
              const DateSubhead('Sat, 8 Nov'),
              ExpenseRow(
                expense: testExpense(
                  id: 'e-dinner',
                  description: "Dinner at Britto's",
                  category: 'food.dining',
                  paid: {'m-me': 600000},
                  owed: {'m-me': 100000, 'm-priya': 250000, 'm-ravi': 250000},
                ),
                memberNames: names,
                myMemberId: 'm-me',
                onTap: _noop,
              ),
              ExpenseRow(
                expense: testExpense(
                  id: 'e-hotel',
                  description: 'Hotel deposit',
                  category: 'transport.hotel',
                  paid: {'m-ravi': 3000000},
                  owed: {
                    'm-me': 500000,
                    'm-priya': 500000,
                    'm-ravi': 500000,
                    'm-kabir': 500000,
                    'm-isha': 500000,
                    'm-neha': 500000,
                  },
                ),
                memberNames: names,
                myMemberId: 'm-me',
                onTap: _noop,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Render 3: Add expense.
class AddExpenseScreen extends StatelessWidget {
  const AddExpenseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: _appBar(
        context,
        leading: IconButton(
          onPressed: _noop,
          tooltip: 'Discard and close',
          icon: const Icon(Icons.close_rounded),
        ),
        title: const Text('Add expense'),
        actions: const [
          DropdownChip(
            label: 'Goa trip',
            onTap: _noop,
            semanticLabel: 'Group: Goa trip. Change group',
          ),
          SizedBox(width: Space.sm),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SplitSummaryBar(
                  summary: '₹600 each, 4 people',
                  leftMinor: 0,
                  currency: 'INR',
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _noop,
                  style: KitButtonStyles.block,
                  child: const Text('Save expense'),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.lg),
        children: [
          const SizedBox(height: 6),
          _t(
            AmountField(
              currency: 'INR',
              initialMinor: 240000,
              currencyName: 'Indian rupees',
              onChanged: (_) {},
            ),
          ),
          const SizedBox(height: 14),
          _g(
            const LabeledTextField(
              label: 'Description',
              trailing: CategoryChip(
                categoryId: 'transport',
                label: 'Transport',
                onTap: _noop,
              ),
            ).withText('Scooter rental'),
          ),
          const SizedBox(height: 10),
          _g(
            const Row(
              children: [
                Expanded(
                  child: PickerTile(
                    label: 'Paid by',
                    value: 'Priya',
                    leading: PersonAvatar(
                      id: 'm-priya',
                      name: 'Priya Sharma',
                      size: Sizes.avatarTiny,
                    ),
                    onTap: _noop,
                  ),
                ),
                SizedBox(width: Space.sm),
                Expanded(
                  child: PickerTile(
                    label: 'Date',
                    value: 'Today, 9 Nov',
                    leading: Icon(Icons.calendar_today_rounded, size: 20),
                    onTap: _noop,
                  ),
                ),
              ],
            ),
          ),
          _g(const SectionHeading('Split equally between 4 of 6')),
          _g(SplitMethodSelector(value: SplitMethod.equal, onChanged: (_) {})),
          const SizedBox(height: 5),
          _g(
            ListSection(
              dividerIndent: 64,
              children: [
                MemberSplitRow(
                  id: 'm-me',
                  name: 'You',
                  avatarName: 'Arjun Mehta',
                  isMe: true,
                  included: true,
                  onChanged: (_) {},
                  currency: 'INR',
                  subtitle: 'you owe Priya',
                  subtitleDirection: MoneyDirection.owe,
                  shareMinor: 60000,
                  shareDirection: MoneyDirection.owe,
                ),
                for (final (id, name, full, sub) in const [
                  ('m-priya', 'Priya', 'Priya Sharma', 'her own share'),
                  ('m-ravi', 'Ravi', 'Ravi Kumar', 'owes Priya'),
                  ('m-neha', 'Neha', 'Neha Joshi', 'owes Priya'),
                ])
                  MemberSplitRow(
                    id: id,
                    name: name,
                    avatarName: full,
                    included: true,
                    onChanged: (_) {},
                    currency: 'INR',
                    subtitle: sub,
                    shareMinor: 60000,
                  ),
                for (final (id, name, full) in const [
                  ('m-kabir', 'Kabir', 'Kabir Singh'),
                  ('m-isha', 'Isha', 'Isha Nair'),
                ])
                  MemberSplitRow(
                    id: id,
                    name: name,
                    avatarName: full,
                    included: false,
                    onChanged: (_) {},
                    currency: 'INR',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on LabeledTextField {
  /// Gallery helper: the same field with text already typed.
  Widget withText(String text) => _Prefilled(field: this, text: text);
}

class _Prefilled extends StatefulWidget {
  const _Prefilled({required this.field, required this.text});

  final LabeledTextField field;
  final String text;

  @override
  State<_Prefilled> createState() => _PrefilledState();
}

class _PrefilledState extends State<_Prefilled> {
  late final controller = TextEditingController(text: widget.text);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LabeledTextField(
    label: widget.field.label,
    trailing: widget.field.trailing,
    controller: controller,
  );
}

/// Render 4: Settle up.
class SettleScreen extends StatelessWidget {
  const SettleScreen({super.key, this.recorded = false});

  final bool recorded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _appBar(
        context,
        leading: IconButton(
          onPressed: _noop,
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
        ),
        title: const AppBarTitle('Settle up', subtitle: 'Goa trip'),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: FilledButton(
            onPressed: _noop,
            style: KitButtonStyles.block,
            child: const Text('Record ₹840 payment'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.lg),
        children: [
          const SizedBox(height: Space.sm),
          _t(
            SettleTether(
              fromId: 'm-me',
              fromName: 'Arjun Mehta',
              toId: 'm-priya',
              toName: 'Priya Sharma',
              amountMinor: 84000,
              currency: 'INR',
              fromIsMe: true,
              question: 'You pay Priya',
              recorded: recorded,
              action: TextLink('Pay part of it', onPressed: _noop),
            ),
          ),
          _g(
            const SectionHeading(
              'How you paid',
              padding: EdgeInsets.fromLTRB(4, 16, 4, Space.sectionBottom),
            ),
          ),
          _g(
            PaymentMethodSelector(value: PaymentMethod.upi, onChanged: (_) {}),
          ),
          _t(
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                'Pay in your UPI app first. This records it; no money moves here.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          _g(
            const SectionHeading(
              'What changes',
              padding: EdgeInsets.fromLTRB(4, 20, 4, Space.sectionBottom),
            ),
          ),
          _g(
            const BeforeAfterTable(
              currency: 'INR',
              entries: [
                BeforeAfterEntry(
                  title: 'You and Priya',
                  subtitle: 'Goa trip',
                  now: BalanceCell(word: 'you owe', minor: -84000),
                  after: BalanceCell(word: 'settled', minor: 0),
                ),
                BeforeAfterEntry(
                  title: 'Priya overall',
                  subtitle: 'All groups',
                  now: BalanceCell(word: 'owes you', minor: 120000),
                  after: BalanceCell(word: 'owes you', minor: 204000),
                ),
                BeforeAfterEntry(
                  title: 'Your overall',
                  now: BalanceCell(word: "you're owed", minor: 425000),
                  after: BalanceCell(word: "you're owed", minor: 509000),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          _g(
            const ListSection(
              children: [
                KeyValueRow(label: 'Date', value: 'Today, 9 Nov', onTap: _noop),
                KeyValueRow(
                  label: 'Note',
                  value: null,
                  placeholder: 'Optional',
                  onTap: _noop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Render 5: Sync.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: _appBar(
        context,
        title: const Text('Sync'),
        actions: [
          IconButton(
            onPressed: _noop,
            tooltip: 'How sync works',
            icon: const Icon(Icons.help_outline_rounded),
          ),
        ],
      ),
      bottomNavigationBar: AppNavigationBar(
        selectedIndex: 2,
        onDestinationSelected: (_) {},
        pendingCount: 3,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          _t(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '3 changes to share',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: Space.xs),
                Text(
                  "2 expenses and 1 payment since you last synced with Priya's "
                  'Pixel 8, yesterday at 9:12 pm.',
                  style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
                ),
                const SizedBox(height: Space.md),
                const SyncTether(),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _g(
            HostQrCard(
              visible: true,
              onVisibleChanged: (_) {},
              subtitle: 'On your hotspot, for 4:58 more',
              qrData: 'settleup://connect?h=192.168.43.1:7420&k=demo',
              address: '192.168.43.1:7420',
              hotspotName: 'AndroidAP_4B',
            ),
          ),
          const SizedBox(height: Space.md),
          _g(
            FilledButton.tonalIcon(
              onPressed: _noop,
              style: KitButtonStyles.block.copyWith(
                minimumSize: const WidgetStatePropertyAll(
                  Size.fromHeight(Sizes.button),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: const Text('Scan a QR'),
            ),
          ),
          _g(const SectionHeading('Nearby phones', action: LookingIndicator())),
          _g(
            const ListSection(
              children: [
                NearbyPhoneRow(
                  name: "Priya's Pixel 8",
                  subtitle: 'Wi-Fi, shares Goa trip',
                  onAction: _noop,
                ),
                NearbyPhoneRow(
                  name: "Ravi's iPhone",
                  subtitle: 'Bluetooth, shares Goa trip',
                  kind: NearbyPhoneKind.iphone,
                  onAction: _noop,
                ),
                NearbyPhoneRow(
                  name: 'Unknown phone',
                  subtitle: 'Bluetooth, no shared groups',
                  kind: NearbyPhoneKind.unknown,
                  action: NearbyPhoneAction.pair,
                  onAction: _noop,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: ink2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Encrypted between phones. A phone only gets the groups '
                    'you both belong to.',
                    style: theme.textTheme.bodySmall!.copyWith(color: ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
