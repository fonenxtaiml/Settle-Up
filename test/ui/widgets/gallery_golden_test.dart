// Widget gallery goldens with the real bundled fonts (SPEC 11.4, DESIGN 5).
// Regenerate with: flutter test --update-goldens test/ui/widgets/gallery_golden_test.dart
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'expense_row_test.dart' as rows;
import 'kit_harness.dart';

const double _width = 412;

void _noop() {}

class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

Widget _gutter(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
  child: child,
);

Widget _divider() => const Divider(indent: Space.rowInset);

Widget balancesPage() => _Page(
  children: [
    const SizedBox(height: Space.x2),
    _gutter(
      Row(
        children: [
          Expanded(
            child: Text(
              'Settle Up',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                fontFamily: 'AtkinsonHyperlegibleNext',
              ),
            ),
          ),
          SyncStatusChip(
            state: SyncChipState.allShared,
            lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
          const SizedBox(width: Space.x2),
          const PersonAvatar(id: 'p-alex', name: 'Alex Lee', size: 32),
        ],
      ),
    ),
    const SizedBox(height: Space.x2),
    _gutter(
      const BalanceHero(
        net: {'GBP': 4250, 'EUR': 1200},
        owedToMe: {'GBP': 5090, 'EUR': 1200},
        iOwe: {'GBP': 840},
        mainCurrency: 'GBP',
      ),
    ),
    const SectionHeader('Unsettled', emphasized: false),
    const BalanceRow(
      kind: BalanceRowKind.group,
      id: 'g-goa',
      title: 'Goa trip',
      subtitle: '6 people',
      net: {'GBP': -840},
    ),
    _divider(),
    const BalanceRow(
      kind: BalanceRowKind.group,
      id: 'g-flat',
      title: 'Flat 4B',
      subtitle: '3 people',
      net: {'GBP': 5090, 'EUR': 1200},
    ),
    const SectionHeader('Settled up', emphasized: false),
    const BalanceRow(
      kind: BalanceRowKind.group,
      id: 'g-cabin',
      title: 'Cabin weekend',
      subtitle: '4 people, settled 2 Nov',
      net: {},
    ),
    const SectionHeader('People'),
    const BalanceRow(
      kind: BalanceRowKind.person,
      id: 'p-sam',
      title: 'Sam Patel',
      subtitle: 'In Flat 4B and Goa trip',
      net: {'GBP': 1200},
    ),
    _divider(),
    const BalanceRow(
      kind: BalanceRowKind.person,
      id: 'p-ravi',
      title: 'Ravi Kumar',
      subtitle: 'In Goa trip',
      net: {'GBP': -960},
      isPlaceholder: true,
    ),
    const SizedBox(height: Space.x4),
    _gutter(
      const BalanceHero(net: {}, owedToMe: {}, iOwe: {}, mainCurrency: 'GBP'),
    ),
    const SizedBox(height: Space.x4),
  ],
);

Widget expensesPage() => _Page(
  children: [
    DateHeader(date: DateTime.now()),
    ExpenseRow(expense: rows.lent, memberNames: rows.names, myMemberId: 'me'),
    ExpenseRow(
      expense: rows.borrowed,
      memberNames: rows.names,
      myMemberId: 'me',
      unshared: true,
    ),
    DateHeader(date: DateTime.now().subtract(const Duration(days: 1))),
    ExpenseRow(
      expense: rows.notInvolved,
      memberNames: rows.names,
      myMemberId: 'me',
    ),
    ExpenseRow(
      expense: rows.multiPayer,
      memberNames: rows.names,
      myMemberId: 'me',
    ),
    ExpenseRow(
      expense: rows.payment,
      memberNames: rows.names,
      myMemberId: 'me',
    ),
    ExpenseRow(
      expense: rows.lent,
      memberNames: rows.names,
      myMemberId: 'me',
      deleted: true,
      onRestore: () {},
    ),
    const SectionHeader('Sync chip'),
    _gutter(
      Wrap(
        spacing: Space.x2,
        children: [
          const SyncStatusChip(state: SyncChipState.neverSynced),
          SyncStatusChip(
            state: SyncChipState.allShared,
            lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
          const SyncStatusChip(
            state: SyncChipState.changesWaiting,
            pendingCount: 3,
          ),
          const SyncStatusChip(
            state: SyncChipState.inProgress,
            peerName: 'Priya',
          ),
          const SyncStatusChip(state: SyncChipState.failed),
        ],
      ),
    ),
    const EmptyState(
      headline: 'Nothing to split yet',
      body: "Add the first expense and everyone's share appears here.",
      actionLabel: 'Add expense',
      onAction: _noop,
    ),
  ],
);

Widget entryPage() => _Page(
  children: [
    const SizedBox(height: Space.x4),
    _gutter(
      AmountKeypad(
        currency: 'GBP',
        valueMinor: 6050,
        onChanged: (_) {},
        onCurrencyTap: () {},
      ),
    ),
    const SizedBox(height: Space.x6),
    _gutter(SplitMethodSelector(value: SplitMethod.exact, onChanged: (_) {})),
    const SizedBox(height: Space.x4),
    _gutter(
      const RemainderBar(
        method: SplitMethod.exact,
        targetUnits: 6000,
        assignedUnits: 5550,
        currency: 'GBP',
      ),
    ),
    const SizedBox(height: Space.x4),
    _gutter(
      const RemainderBar(
        method: SplitMethod.percent,
        targetUnits: 10000,
        assignedUnits: 10000,
        currency: 'GBP',
      ),
    ),
    const SizedBox(height: Space.x4),
    _gutter(
      const RemainderBar(
        method: SplitMethod.exact,
        targetUnits: 6000,
        assignedUnits: 6200,
        currency: 'GBP',
      ),
    ),
    const SizedBox(height: Space.x6),
    _gutter(
      const Row(
        children: [
          PersonAvatar(id: 'p-alex', name: 'Alex Lee', size: 56),
          SizedBox(width: Space.x3),
          PersonAvatar(id: 'p-priya', name: 'Priya', size: 40),
          SizedBox(width: Space.x3),
          PersonAvatar(id: 'p-sam', name: 'Sam Patel', size: 32),
          SizedBox(width: Space.x3),
          PersonAvatar(id: 'p-ravi', name: 'Ravi', size: 24),
          SizedBox(width: Space.x3),
          PersonAvatar(id: 'p-jo', name: 'Jo Marsh', isPlaceholder: true),
          SizedBox(width: Space.x3),
          GroupGlyph(id: 'g-flat', name: 'Flat 4B'),
        ],
      ),
    ),
    const SizedBox(height: Space.x4),
    _gutter(
      Wrap(
        spacing: Space.x2,
        runSpacing: Space.x2,
        children: [
          for (final id in [
            'food.dining',
            'food.groceries',
            'transport.taxi',
            'transport.plane',
            'transport.hotel',
            'home.rent',
            'utilities.electricity',
            'entertainment.movies',
            'life.gifts',
            'general',
            'payment',
          ])
            CategoryGlyph(categoryId: id),
        ],
      ),
    ),
    const SizedBox(height: Space.x4),
  ],
);

Widget nearbyPage() => _Page(
  children: [
    Builder(
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 22),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const NearbySheetHeader(),
            const SizedBox(height: Space.x2),
            const NearbyPeerRow(
              id: 'p-priya',
              name: "Priya's Pixel 8",
              transports: {TransportKind.lan, TransportKind.ble},
              sharedGroupNames: ['Goa trip'],
              onSync: _noop,
              fadeIn: false,
            ),
            const NearbyPeerRow(
              id: 'p-ravi',
              name: "Ravi's iPhone",
              transports: {TransportKind.ble},
              sharedGroupNames: ['Flat 4B', 'Goa trip'],
              onSync: _noop,
              fadeIn: false,
            ),
            const NearbyPeerRow(
              id: 'x',
              name: '',
              transports: {TransportKind.ble},
              sharedGroupNames: [],
              onPair: _noop,
              fadeIn: false,
            ),
            const NearbySheetFooter(onShowQr: _noop, onScanQr: _noop),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: PairingCode(code: '482913', peerName: 'Priya'),
            ),
          ],
        ),
      ),
    ),
  ],
);

void main() {
  setUpAll(() async {
    configureKitTests();
    await loadRealFonts();
  });

  final pages = <String, (Widget Function(), double)>{
    'balances': (balancesPage, 1040),
    'expenses': (expensesPage, 1000),
    'entry': (entryPage, 1000),
    'nearby': (nearbyPage, 760),
  };

  for (final MapEntry(key: name, value: (build, height)) in pages.entries) {
    for (final b in Brightness.values) {
      final mode = b == Brightness.dark ? 'dark' : 'light';
      testWidgets('gallery $name $mode', (tester) async {
        tester.view.physicalSize = Size(_width * 2, height * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          kitApp(
            RepaintBoundary(key: const ValueKey('gallery'), child: build()),
            brightness: b,
            disableAnimations: true,
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await expectLater(
          find.byKey(const ValueKey('gallery')),
          matchesGoldenFile('goldens/gallery_${name}_$mode.png'),
        );
      });
    }
  }

  testWidgets('gallery balances light large text', (tester) async {
    tester.view.physicalSize = const Size(_width * 2, 1500 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      kitApp(
        RepaintBoundary(key: const ValueKey('gallery'), child: balancesPage()),
        textScale: 2,
        disableAnimations: true,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await expectLater(
      find.byKey(const ValueKey('gallery')),
      matchesGoldenFile('goldens/gallery_balances_light_2x.png'),
    );
  });
}
