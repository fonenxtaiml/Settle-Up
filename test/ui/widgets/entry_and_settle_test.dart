import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  group('AmountField', () {
    final inr = Currencies.of('INR');
    final jpy = Currencies.of('JPY');

    test('groups as you type, lakh style for rupees', () {
      expect(AmountField.groupForDisplay('2400', inr), '2,400');
      expect(AmountField.groupForDisplay('120000', inr), '1,20,000');
      expect(AmountField.groupForDisplay('1,2,0000', inr), '1,20,000');
      expect(AmountField.groupForDisplay('0042', inr), '42');
      expect(AmountField.groupForDisplay('12.345', inr), '12.34');
      expect(AmountField.groupForDisplay('.5', inr), '0.5');
      expect(AmountField.groupForDisplay('1.2.3', inr), '1.23');
      expect(AmountField.groupForDisplay('500.5', jpy), '500');
      expect(
        AmountField.groupForDisplay('1234567', Currencies.of('GBP')),
        '1,234,567',
      );
      expect(AmountField.groupForDisplay('', inr), '');
    });

    test('parses to integer minor units', () {
      expect(AmountField.parse('2,400', inr), 240000);
      expect(AmountField.parse('1,20,000.50', inr), 12000050);
      expect(AmountField.parse('', inr), isNull);
      expect(AmountField.textFor(240000, inr), '2,400');
      expect(AmountField.textFor(240050, inr), '2,400.50');
    });

    testKitVariants(
      'with an initial amount',
      () => AmountField(
        currency: 'INR',
        initialMinor: 240000,
        currencyName: 'Indian rupees',
        onChanged: (_) {},
      ),
      verify: (tester, _) async {
        expect(find.text('2,400'), findsOneWidget);
        expect(find.text('₹'), findsOneWidget);
        expect(find.text('Amount'), findsOneWidget);
      },
    );

    testWidgets('typing reports minor units and keeps the grouping', (
      tester,
    ) async {
      int? value;
      await tester.pumpWidget(
        kitApp(AmountField(currency: 'INR', onChanged: (v) => value = v)),
      );
      await tester.enterText(find.byType(TextField), '120000');
      expect(value, 12000000);
      expect(find.text('1,20,000'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      expect(value, isNull);
    });

    testWidgets('error text is shown and announced', (tester) async {
      await tester.pumpWidget(
        kitApp(
          AmountField(
            currency: 'INR',
            onChanged: (_) {},
            errorText: 'Enter an amount above ₹0',
          ),
        ),
      );
      expect(find.text('Enter an amount above ₹0'), findsOneWidget);
    });

    testWidgets('the symbol opens the currency picker when allowed', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          AmountField(
            currency: 'INR',
            onChanged: (_) {},
            onCurrencyTap: () => taps++,
          ),
        ),
      );
      await tester.tap(find.text('₹'));
      expect(taps, 1);
    });
  });

  group('form tiles', () {
    testKitVariants(
      'description, category, pickers, key-value rows, dropdown chip',
      () => Column(
        children: [
          const LabeledTextField(
            label: 'Description',
            hintText: 'What was it for?',
            trailing: CategoryChip(categoryId: 'transport', label: 'Transport'),
          ),
          const SizedBox(height: 8),
          const LabeledTextField(label: 'Note', errorText: 'Too long'),
          const SizedBox(height: 8),
          const Row(
            children: [
              Expanded(
                child: PickerTile(
                  label: 'Paid by',
                  value: 'Priya',
                  leading: PersonAvatar(id: 'p', name: 'Priya', size: 26),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: PickerTile(
                  label: 'Date',
                  value: 'Today, 9 Nov',
                  leading: Icon(Icons.calendar_today_rounded, size: 20),
                ),
              ),
            ],
          ),
          ListSection(
            children: [
              KeyValueRow(label: 'Date', value: 'Today, 9 Nov', onTap: () {}),
              KeyValueRow(
                label: 'Note',
                value: null,
                placeholder: 'Optional',
                onTap: () {},
              ),
            ],
          ),
          DropdownChip(label: 'Goa trip', onTap: () {}),
          const AppBarTitle('Goa trip', subtitle: '6 people, ₹38,400 spent'),
        ],
      ),
      verify: (tester, _) async {
        expect(find.text('Transport'), findsOneWidget);
        expect(find.text('Optional'), findsOneWidget);
        expect(find.text('Too long'), findsOneWidget);
      },
    );

    testWidgets('tiles are labelled buttons', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          Column(
            children: [
              PickerTile(label: 'Paid by', value: 'Priya', onTap: () => taps++),
              CategoryChip(
                categoryId: 'transport',
                label: 'Transport',
                onTap: () => taps++,
              ),
              DropdownChip(
                label: 'Goa trip',
                semanticLabel: 'Group: Goa trip. Change group',
                onTap: () => taps++,
              ),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Paid by, Priya'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Category: Transport. Change category'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Group: Goa trip. Change group'),
        findsOneWidget,
      );
      await tester.tap(find.text('Priya'));
      await tester.tap(find.text('Transport'));
      await tester.tap(find.text('Goa trip'));
      expect(taps, 3);
      handle.dispose();
    });
  });

  group('split controls', () {
    testKitVariants(
      'method chips',
      () => SplitMethodSelector(value: SplitMethod.equal, onChanged: (_) {}),
      verify: (tester, _) async {
        for (final l in [
          'Equally',
          'Exact amounts',
          'Percent',
          'Shares',
          'Adjust',
        ]) {
          expect(find.text(l), findsOneWidget);
        }
      },
    );

    testWidgets('choosing a method; selected chip is filled ink', (
      tester,
    ) async {
      SplitMethod? picked;
      await tester.pumpWidget(
        kitApp(
          SplitMethodSelector(
            value: SplitMethod.equal,
            onChanged: (m) => picked = m,
          ),
        ),
      );
      await tester.tap(find.text('Shares'));
      expect(picked, SplitMethod.shares);
      picked = null;
      await tester.tap(find.text('Equally'));
      expect(picked, isNull);
      final selected = tester.widget<Text>(find.text('Equally'));
      expect(selected.style!.color, Colors.white);
    });

    testWidgets('chips are a labelled, exclusive group', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          SplitMethodSelector(value: SplitMethod.percent, onChanged: (_) {}),
        ),
      );
      final node = tester.getSemantics(find.text('Percent'));
      expect(node.label, 'Percent');
      expect(node.flagsCollection.isChecked, isNotNull);
      handle.dispose();
    });

    Widget members({ValueChanged<bool>? onChanged}) => ListSection(
      dividerIndent: 64,
      children: [
        MemberSplitRow(
          id: 'me',
          name: 'You',
          avatarName: 'Arjun Mehta',
          isMe: true,
          included: true,
          onChanged: onChanged ?? (_) {},
          currency: 'INR',
          subtitle: 'you owe Priya',
          subtitleDirection: MoneyDirection.owe,
          shareMinor: 60000,
          shareDirection: MoneyDirection.owe,
        ),
        MemberSplitRow(
          id: 'p',
          name: 'Priya',
          included: true,
          onChanged: (_) {},
          currency: 'INR',
          subtitle: 'her own share',
          shareMinor: 60000,
        ),
        MemberSplitRow(
          id: 'k',
          name: 'Kabir',
          included: false,
          onChanged: (_) {},
          currency: 'INR',
          shareMinor: 60000,
        ),
      ],
    );

    testKitVariants(
      'member rows',
      members,
      verify: (tester, _) async {
        expect(find.text('−₹600'), findsOneWidget);
        expect(find.text('₹600'), findsOneWidget);
        expect(find.text('not in this expense'), findsOneWidget);
        expect(find.byType(Checkbox), findsNWidgets(3));
      },
    );

    testWidgets('the whole row toggles', (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(kitApp(members(onChanged: changes.add)));
      await tester.tap(find.text('you owe Priya'));
      await tester.tap(find.byType(Checkbox).first);
      expect(changes, [false, false]);
    });

    testWidgets('your share is Kiln with a tether on the subline', (
      tester,
    ) async {
      await tester.pumpWidget(kitApp(members()));
      expect(
        tester.widget<Text>(find.text('−₹600')).style!.color,
        MoneyColors.light.owe,
      );
      expect(find.byType(TetherGlyph), findsOneWidget);
    });

    testKitVariants(
      'summary bar: done and over',
      () => const Column(
        children: [
          SplitSummaryBar(
            summary: '₹600 each, 4 people',
            leftMinor: 0,
            currency: 'INR',
          ),
          SplitSummaryBar(
            summary: 'Exact amounts',
            leftMinor: -20000,
            currency: 'INR',
          ),
          SplitSummaryBar(
            summary: 'Exact amounts',
            leftMinor: 45000,
            currency: 'INR',
          ),
        ],
      ),
      verify: (tester, _) async {
        expect(find.textContaining('left to split'), findsNWidgets(2));
        expect(find.textContaining('too much'), findsOneWidget);
      },
    );

    testWidgets('summary bar is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          const SplitSummaryBar(
            summary: '₹600 each, 4 people',
            leftMinor: 0,
            currency: 'INR',
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('₹600 each, 4 people. 0.00 INR left to split'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('settle up controls', () {
    testKitVariants(
      'payment method segments',
      () => PaymentMethodSelector(value: PaymentMethod.upi, onChanged: (_) {}),
      verify: (tester, _) async {
        for (final l in ['UPI', 'Cash', 'Bank', 'Other']) {
          expect(find.text(l), findsOneWidget);
        }
      },
    );

    testWidgets('choosing a method', (tester) async {
      PaymentMethod? picked;
      await tester.pumpWidget(
        kitApp(
          PaymentMethodSelector(
            value: PaymentMethod.upi,
            onChanged: (m) => picked = m,
          ),
        ),
      );
      await tester.tap(find.text('Bank'));
      expect(picked, PaymentMethod.bank);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    const table = BeforeAfterTable(
      currency: 'INR',
      entries: [
        BeforeAfterEntry(
          title: 'You and Priya',
          subtitle: 'Goa trip',
          now: BalanceCell(word: 'you owe', minor: -84000),
          after: BalanceCell(word: 'settled', minor: 0),
        ),
        BeforeAfterEntry(
          title: 'Your overall',
          now: BalanceCell(word: "you're owed", minor: 425000),
          after: BalanceCell(word: "you're owed", minor: 509000),
        ),
      ],
    );

    testKitVariants(
      'before/after table',
      () => table,
      verify: (tester, v) async {
        // Stacked at text scale 2: every row labels its own cells.
        final perRow = v.$2 >= 2 ? 2 : 1;
        expect(find.text('Now'), findsNWidgets(perRow));
        expect(find.text('After'), findsNWidgets(perRow));
        expect(find.text('−₹840'), findsOneWidget);
        expect(find.text('₹0'), findsOneWidget);
        expect(find.text('+₹5,090'), findsOneWidget);
      },
    );

    testWidgets('each row reads now and after', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(kitApp(table));
      expect(
        find.bySemanticsLabel(
          'You and Priya, Goa trip, Now you owe 840.00 INR, '
          'After settled 0.00 INR',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
