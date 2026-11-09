import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  group('BalanceHero', () {
    testKitVariants(
      'owed, with a second currency',
      () => const BalanceHero(
        net: {'INR': 425000, 'EUR': -1200},
        owedToMe: {'INR': 509000},
        iOwe: {'INR': 84000, 'EUR': 1200},
        mainCurrency: 'INR',
      ),
      verify: (tester, _) async {
        expect(find.text("You're owed overall"), findsOneWidget);
        expect(find.text('Coming to you'), findsOneWidget);
        expect(find.text('+₹5,090'), findsOneWidget);
        expect(find.text('−₹840'), findsOneWidget);
        expect(find.text('Plus €12.00 you owe'), findsOneWidget);
      },
    );

    testKitVariants(
      'owe',
      () => const BalanceHero(
        net: {'INR': -84000},
        owedToMe: {'INR': 0},
        iOwe: {'INR': 84000},
        mainCurrency: 'INR',
      ),
      verify: (tester, _) async {
        expect(find.text('You owe overall'), findsOneWidget);
      },
    );

    testKitVariants(
      'settled',
      () => const BalanceHero(
        net: {},
        owedToMe: {},
        iOwe: {},
        mainCurrency: 'INR',
      ),
      verify: (tester, _) async {
        expect(find.text("You're all settled up"), findsOneWidget);
        expect(find.byType(TetherGlyph), findsOneWidget);
      },
    );

    testWidgets('sentence carries the colour, the number stays ink', (
      tester,
    ) async {
      await tester.pumpWidget(
        kitApp(
          const BalanceHero(
            net: {'INR': 425000},
            owedToMe: {'INR': 509000},
            iOwe: {'INR': 84000},
            mainCurrency: 'INR',
          ),
        ),
      );
      final sentence = tester.widget<Text>(find.text("You're owed overall"));
      expect(sentence.style!.color, MoneyColors.light.owed);
      final number = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) =>
              w is Text && w.textSpan?.toPlainText().contains('4,250') == true,
        ),
      );
      expect(number.style!.color, const Color(0xFF16191D));
    });

    testWidgets('one semantics node, tappable', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          BalanceHero(
            net: const {'INR': 425000},
            owedToMe: const {'INR': 509000},
            iOwe: const {'INR': 84000},
            mainCurrency: 'INR',
            onTap: () => taps++,
          ),
        ),
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r"^You're owed overall\. 4250\.00 INR\. Coming to you"),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(BalanceHero));
      expect(taps, 1);
      handle.dispose();
    });
  });

  group('GroupBalanceHero', () {
    testKitVariants(
      'owe with detail',
      () => const GroupBalanceHero(
        minor: -84000,
        currency: 'INR',
        detail: 'You paid ₹6,000 and your share is ₹6,840.',
      ),
      verify: (tester, _) async {
        expect(find.text('You owe in this group'), findsOneWidget);
      },
    );
    testKitVariants(
      'owed and settled',
      () => const Column(
        children: [
          GroupBalanceHero(minor: 120000, currency: 'INR'),
          GroupBalanceHero(minor: 0, currency: 'INR'),
        ],
      ),
      verify: (tester, _) async {
        expect(find.text("You're owed in this group"), findsOneWidget);
        expect(find.text("You're settled up in this group"), findsOneWidget);
      },
    );
  });

  group('BalanceRow', () {
    Widget rows() => const ListSection(
      title: 'People',
      dividerIndent: Space.avatarRowInset,
      children: [
        BalanceRow(
          kind: BalanceRowKind.person,
          id: 'p1',
          title: 'Priya Sharma',
          subtitle: 'Goa trip, Flat 4B',
          net: {'INR': 120000},
        ),
        BalanceRow(
          kind: BalanceRowKind.group,
          id: 'g1',
          title: 'Goa trip',
          subtitle: '6 people',
          net: {'INR': -84000, 'EUR': 500},
        ),
        BalanceRow(
          kind: BalanceRowKind.group,
          id: 'g2',
          title: 'Cabin weekend',
          subtitle: '4 people',
          net: {'INR': 0},
        ),
        BalanceRow(
          kind: BalanceRowKind.member,
          id: 'm1',
          title: 'Ravi Kumar',
          subtitle: 'Paid ₹30,000',
          net: {'INR': 2500000},
        ),
        BalanceRow(
          kind: BalanceRowKind.person,
          id: 'p2',
          title: 'Kabir',
          subtitle: 'Not on Settle Up yet',
          net: {'INR': -500},
          isPlaceholder: true,
        ),
      ],
    );

    testKitVariants(
      'person, group, member, placeholder',
      rows,
      verify: (tester, _) async {
        expect(find.text('owes you'), findsOneWidget);
        expect(find.text('+₹1,200'), findsOneWidget);
        expect(find.text('you owe'), findsNWidgets(2));
        expect(find.text('−₹840'), findsOneWidget);
        expect(find.text('+1 more'), findsOneWidget);
        expect(find.text('settled up'), findsOneWidget);
        // Member rows are third person, unsigned, in ink.
        expect(find.text('gets back'), findsOneWidget);
        expect(find.text('₹25,000'), findsOneWidget);
      },
    );

    testWidgets('groups have no leading tile, people have initials', (
      tester,
    ) async {
      await tester.pumpWidget(kitApp(rows()));
      expect(find.text('PS'), findsOneWidget);
      expect(find.text('GT'), findsNothing);
      expect(find.byType(PersonAvatar), findsNWidgets(3));
    });

    test('word table', () {
      expect(BalanceRow.wordFor(BalanceRowKind.person, 1), 'owes you');
      expect(BalanceRow.wordFor(BalanceRowKind.person, -1), 'you owe');
      expect(BalanceRow.wordFor(BalanceRowKind.group, 1), "you're owed");
      expect(BalanceRow.wordFor(BalanceRowKind.member, -1), 'owes');
      expect(BalanceRow.wordFor(BalanceRowKind.member, 0), 'settled up');
      expect(BalanceRow.mainEntry({'A': 0}), isNull);
      expect(BalanceRow.mainEntry({'A': 5, 'B': -9})!.key, 'B');
    });

    testWidgets('semantics: name, subtitle, direction and amount', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          BalanceRow(
            kind: BalanceRowKind.group,
            id: 'g1',
            title: 'Goa trip',
            subtitle: '6 people',
            net: const {'INR': -84000},
            onTap: () => taps++,
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('Goa trip, 6 people, you owe 840.00 INR'),
        findsOneWidget,
      );
      await tester.tap(find.text('Goa trip'));
      expect(taps, 1);
      handle.dispose();
    });
  });

  group('ExpenseRow', () {
    const names = {'me': 'You', 'p': 'Priya', 'r': 'Ravi', 'k': 'Kabir'};

    Widget list({bool unshared = false, bool deleted = false}) => ListSection(
      children: [
        const DateSubhead('Today'),
        ExpenseRow(
          expense: testExpense(
            description: 'Scooter rental',
            category: 'transport',
            paid: {'p': 240000},
            owed: {'me': 60000, 'p': 60000, 'r': 60000, 'k': 60000},
          ),
          memberNames: names,
          myMemberId: 'me',
          unshared: unshared,
        ),
        ExpenseRow(
          expense: testExpense(
            description: "Dinner at Britto's",
            paid: {'me': 600000},
            owed: {'me': 100000, 'p': 500000},
          ),
          memberNames: names,
          myMemberId: 'me',
        ),
        ExpenseRow(
          expense: testExpense(
            description: 'Taxi',
            category: 'transport.taxi',
            paid: {'r': 50000},
            owed: {'r': 25000, 'k': 25000},
          ),
          memberNames: names,
          myMemberId: 'me',
          deleted: deleted,
          onRestore: deleted ? () {} : null,
        ),
        ExpenseRow(
          expense: testExpense(
            kind: ExpenseKind.payment,
            paid: {'r': 200000},
            owed: {'me': 200000},
          ),
          memberNames: names,
          myMemberId: 'me',
        ),
        ExpenseRow(
          expense: testExpense(
            kind: ExpenseKind.payment,
            paid: {'me': 84000},
            owed: {'p': 84000},
            paymentMethod: PaymentMethod.cash,
          ),
          memberNames: names,
          myMemberId: 'me',
        ),
        ExpenseRow(
          expense: testExpense(
            kind: ExpenseKind.payment,
            paid: {'k': 615000},
            owed: {'r': 615000},
          ),
          memberNames: names,
          myMemberId: 'me',
        ),
      ],
    );

    testKitVariants(
      'expenses and payments',
      list,
      verify: (tester, _) async {
        expect(find.text('Priya paid ₹2,400'), findsOneWidget);
        expect(find.text('you borrowed'), findsOneWidget);
        expect(find.text('−₹600'), findsOneWidget);
        expect(find.text('you lent'), findsOneWidget);
        expect(find.text('+₹5,000'), findsOneWidget);
        expect(find.text('not involved'), findsOneWidget);
        expect(find.text('Ravi paid you'), findsOneWidget);
        expect(find.text('Payment, UPI'), findsNWidgets(2));
        expect(find.text('received'), findsOneWidget);
        expect(find.text('₹2,000'), findsOneWidget);
        expect(find.text('You paid Priya'), findsOneWidget);
        expect(find.text('Payment, Cash'), findsOneWidget);
        expect(find.text('Kabir paid Ravi'), findsOneWidget);
        expect(find.text('₹6,150'), findsOneWidget);
      },
    );

    testKitVariants(
      'unshared and deleted',
      () => list(unshared: true, deleted: true),
      verify: (tester, _) async {
        expect(find.text('Restore'), findsOneWidget);
        expect(find.byType(Tooltip), findsOneWidget);
      },
    );

    testWidgets('unshared rows say so to screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(kitApp(list(unshared: true)));
      expect(
        find.bySemanticsLabel(
          'Scooter rental, Priya paid ₹2,400, you borrowed 600.00 INR, '
          'Not yet shared',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    test('impact', () {
      final e = testExpense(paid: {'a': 100}, owed: {'a': 50, 'b': 50});
      expect(ExpenseRow.impactOf(e, 'a'), ExpenseImpact.lent);
      expect(ExpenseRow.impactOf(e, 'b'), ExpenseImpact.borrowed);
      expect(ExpenseRow.impactOf(e, 'c'), ExpenseImpact.notInvolved);
      expect(ExpenseRow.impactOf(e, null), ExpenseImpact.notInvolved);
      final even = testExpense(paid: {'a': 50}, owed: {'a': 50});
      expect(ExpenseRow.impactOf(even, 'a'), ExpenseImpact.even);
    });
  });

  group('TransferRow and suggested payments', () {
    Widget card() => ListSection(
      header: SuggestedPaymentsHeader(
        simplify: true,
        onSimplifyChanged: (_) {},
      ),
      children: const [
        TransferRow(
          fromId: 'me',
          fromName: 'Arjun Mehta',
          toId: 'p',
          toName: 'Priya Sharma',
          amountMinor: 84000,
          currency: 'INR',
          fromIsMe: true,
        ),
        TransferRow(
          fromId: 'r',
          fromName: 'Ravi Kumar',
          toId: 'me',
          toName: 'Arjun Mehta',
          amountMinor: 50000,
          currency: 'INR',
          toIsMe: true,
        ),
        TransferRow(
          fromId: 'k',
          fromName: 'Kabir Singh',
          toId: 'r',
          toName: 'Ravi Kumar',
          amountMinor: 615000,
          currency: 'INR',
        ),
      ],
    );

    testKitVariants(
      'three directions',
      card,
      verify: (tester, _) async {
        expect(find.text('You pay Priya'), findsOneWidget);
        expect(find.text('−₹840'), findsOneWidget);
        expect(find.text('Ravi pays you'), findsOneWidget);
        expect(find.text('+₹500'), findsOneWidget);
        expect(find.text('Kabir pays Ravi'), findsOneWidget);
        expect(find.text('₹6,150'), findsOneWidget);
        expect(find.text('Suggested payments'), findsOneWidget);
      },
    );

    testWidgets('simplify switch reports changes', (tester) async {
      bool? value;
      await tester.pumpWidget(
        kitApp(
          SuggestedPaymentsHeader(
            simplify: true,
            onSimplifyChanged: (v) => value = v,
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      expect(value, isFalse);
    });

    testWidgets('row tap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          TransferRow(
            fromId: 'me',
            fromName: 'Arjun',
            toId: 'p',
            toName: 'Priya',
            amountMinor: 100,
            currency: 'INR',
            fromIsMe: true,
            label: 'Pay Priya',
            onTap: () => taps++,
          ),
        ),
      );
      await tester.tap(find.text('Pay Priya'));
      expect(taps, 1);
    });
  });

  group('lists and avatars', () {
    testKitVariants(
      'section with heading link and date subheads',
      () => ListSection(
        title: 'Groups',
        titleAction: TextLink('See all', onPressed: () {}),
        children: const [
          DateSubhead('Today'),
          KitListRow(title: 'One', subtitle: 'first'),
          KitListRow(title: 'Two', subtitle: 'second'),
        ],
      ),
      verify: (tester, _) async {
        // A divider between the two rows, none after the subhead.
        expect(find.byType(Divider), findsOneWidget);
        expect(find.text('See all'), findsOneWidget);
      },
    );

    testWidgets('TextLink is a button with a 32 dp target', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        kitApp(TextLink('See all', onPressed: () => taps++)),
      );
      await tester.tap(find.text('See all'));
      expect(taps, 1);
      expect(
        tester.getSize(find.byType(TextLink)).height,
        greaterThanOrEqualTo(kTextLinkHeight),
      );
    });

    testKitVariants(
      'avatars',
      () => const Wrap(
        spacing: 8,
        children: [
          PersonAvatar(id: 'a', name: 'Arjun Mehta', isMe: true),
          PersonAvatar(id: 'b', name: 'Priya Sharma'),
          PersonAvatar(id: 'c', name: 'Ravi', ring: true, size: 56),
          PersonAvatar(id: 'd', name: 'Kabir Singh', size: 26),
          PersonAvatar(id: 'e', name: 'Neha', isPlaceholder: true, size: 32),
        ],
      ),
    );

    test('initials', () {
      expect(PersonAvatar.initialsOf('Priya Sharma'), 'PS');
      expect(PersonAvatar.initialsOf('ravi'), 'R');
      expect(PersonAvatar.initialsOf('  Neha  Jain Rao '), 'NR');
      expect(PersonAvatar.initialsOf(''), '?');
    });

    testWidgets('you are filled ink; placeholders are labelled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          const Row(
            children: [
              PersonAvatar(id: 'a', name: 'Arjun Mehta', isMe: true),
              PersonAvatar(id: 'e', name: 'Neha', isPlaceholder: true),
            ],
          ),
        ),
      );
      final me = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(PersonAvatar).first,
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((me.decoration as BoxDecoration).color, const Color(0xFF16191D));
      expect(find.bySemanticsLabel('not on Settle Up yet'), findsOneWidget);
      handle.dispose();
    });

    testKitVariants(
      'category glyphs',
      () => const Wrap(
        children: [
          CategoryGlyph(categoryId: 'transport'),
          CategoryGlyph(categoryId: 'food.dining'),
          CategoryGlyph(categoryId: 'transport.hotel'),
          CategoryGlyph(categoryId: 'unknown.thing'),
        ],
      ),
    );

    test('category icons fall back to the parent, then a receipt', () {
      expect(CategoryGlyph.iconFor('transport'), Icons.two_wheeler_rounded);
      expect(CategoryGlyph.iconFor('food.dining'), Icons.restaurant_rounded);
      expect(CategoryGlyph.iconFor('food.unknown'), Icons.restaurant_rounded);
      expect(CategoryGlyph.iconFor('nope'), Icons.receipt_long_rounded);
    });

    testKitVariants(
      'empty state',
      () => EmptyState(
        headline: 'Nothing to split yet',
        body: "Add the first expense and everyone's share appears here.",
        actionLabel: 'Add expense',
        onAction: () {},
      ),
      verify: (tester, _) async {
        expect(
          find.widgetWithText(FilledButton, 'Add expense'),
          findsOneWidget,
        );
      },
    );
  });
}
