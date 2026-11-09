import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  final fiveMinAgo = DateTime.now().subtract(const Duration(minutes: 5));

  testKitVariants(
    'sync chips in every state',
    () => Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        children: [
          const SyncStatusChip(state: SyncChipState.neverSynced),
          SyncStatusChip(
            state: SyncChipState.allShared,
            lastSyncedAt: fiveMinAgo,
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
    verify: (tester, v) async {
      expect(find.text('On this phone'), findsOneWidget);
      expect(find.text('Synced 5 min ago'), findsOneWidget);
      expect(find.text('3 changes to share'), findsOneWidget);
      expect(find.text('Syncing with Priya'), findsOneWidget);
      expect(find.text('Sync stopped'), findsOneWidget);
      expect(find.textContaining('ffline'), findsNothing);
    },
  );

  test('chip labels', () {
    expect(
      const SyncStatusChip(
        state: SyncChipState.changesWaiting,
        pendingCount: 1,
      ).label(),
      '1 change to share',
    );
    expect(
      const SyncStatusChip(state: SyncChipState.allShared).label(),
      'Synced',
    );
    expect(
      const SyncStatusChip(state: SyncChipState.inProgress).label(),
      'Syncing',
    );
  });

  testKitVariants(
    'empty state with action',
    () => EmptyState(
      headline: 'Start your first group',
      body: "Groups keep a flat, a trip or a couple's spending in one place.",
      actionLabel: 'Create group',
      onAction: () {},
    ),
    verify: (tester, v) async {
      expect(find.byType(LevelVial), findsOneWidget);
      expect(find.text('Create group'), findsOneWidget);
    },
  );

  testWidgets('empty state without action has no button', (tester) async {
    await tester.pumpWidget(
      kitApp(
        const EmptyState(
          headline: 'No activity yet',
          body: 'Every expense, payment and sync will be listed here.',
        ),
      ),
    );
    expect(find.byType(FilledButton), findsNothing);
  });

  testKitVariants(
    'money text styles',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MoneyText(minor: 4250, currency: 'GBP', style: MoneyTextStyle.hero),
          MoneyText(minor: -840, currency: 'GBP'),
          MoneyText(minor: 0, currency: 'GBP', style: MoneyTextStyle.keypad),
          MoneyText(
            minor: 500,
            currency: 'JPY',
            style: MoneyTextStyle.inline,
            signed: false,
            colored: false,
          ),
        ],
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('+£42.50'), findsOneWidget);
      expect(find.text('−£8.40'), findsOneWidget);
      expect(find.text('£0.00'), findsOneWidget);
      expect(find.text('¥500'), findsOneWidget);
    },
  );

  testKitVariants(
    'section and date headers',
    () => Column(
      children: [
        const SectionHeader('Unsettled', emphasized: false),
        const SectionHeader('Money'),
        DateHeader(date: DateTime.now()),
      ],
    ),
    verify: (tester, v) async => expect(find.text('Today'), findsOneWidget),
  );
}
