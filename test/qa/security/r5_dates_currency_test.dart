// QA SECURITY round 5: regression sweep around the SECURITY-R4-01 (peer
// dates held to 1900..9999) and SECURITY-R4-02 (peer currency codes held
// to ^[A-Z]{3}$) fixes.
//
// The remote check (TextRules.remoteProblem) is probed at the exact edges
// of the new windows on every date field of every entity, with near-miss
// currency codes, and with numbers of the wrong JSON type. The screens
// are then probed with dates that the remote check now accepts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../ui/screens/screen_harness.dart';

Operation _update(EntityType type, Map<String, Object?> payload) => Operation(
  id: 'probe',
  groupId: 'g',
  deviceId: 'd',
  counter: 1,
  hlc: const Hlc(1, 0, 'd'),
  entityType: type,
  entityId: type == EntityType.group ? 'g' : 'e',
  kind: OpKind.update,
  payload: payload,
);

Map<String, Object?> _money(Object? currency) => {
  'total': 100,
  'currency': currency,
  'paidBy': {
    'method': 'exact',
    'values': {'m1': 100},
  },
  'owedBy': {
    'method': 'equal',
    'values': {'m1': 1, 'm2': 1},
  },
  'paid': {'m1': 100},
  'owed': {'m1': 50, 'm2': 50},
};

void main() {
  group('round 5: date window edges on every date field', () {
    final fields = <(EntityType, String)>[
      (EntityType.group, GroupFields.createdAt),
      (EntityType.group, GroupFields.deletedAt),
      (EntityType.member, MemberFields.createdAt),
      (EntityType.member, MemberFields.deletedAt),
      (EntityType.expense, ExpenseFields.date),
      (EntityType.expense, ExpenseFields.createdAt),
      (EntityType.expense, ExpenseFields.deletedAt),
    ];
    for (final (type, field) in fields) {
      test('${type.name}.$field: inside accepted, one ms outside refused', () {
        const min = TextRules.minModelDateMs;
        const max = TextRules.maxModelDateMs;
        for (final ok in [min, 0, 1762700000000, max]) {
          expect(
            TextRules.remoteProblem(_update(type, {field: ok})),
            isNull,
            reason: '$ok',
          );
        }
        for (final bad in [
          min - 1,
          max + 1,
          -TextRules.maxDateMs,
          TextRules.maxDateMs,
          // The wrong JSON number type for a date.
          1762700000000.0,
          '1762700000000',
          true,
        ]) {
          expect(
            TextRules.remoteProblem(_update(type, {field: bad})),
            isNotNull,
            reason: '$bad',
          );
        }
      });
    }

    test('the window edges are the documented calendar days', () {
      expect(utcFromMillis(TextRules.minModelDateMs), DateTime.utc(1900));
      expect(utcFromMillis(TextRules.maxModelDateMs + 1), DateTime.utc(10000));
    });
  });

  group('round 5: near-miss currency codes', () {
    const good = ['INR', 'USD', 'EUR', 'XXX', 'AAA', 'ZZZ'];
    const bad = <Object?>[
      'inr',
      'Inr',
      'IN',
      'INRR',
      ' INR',
      'INR ',
      'INR\n',
      'IN\u0000',
      'I​NR',
      'İNR', // dotted capital I
      'ＩＮＲ', // full-width INR
      'IN1',
      '',
      null,
      7,
      ['INR'],
    ];
    test('group currency', () {
      for (final c in good) {
        expect(
          TextRules.remoteProblem(
            _update(EntityType.group, {GroupFields.currency: c}),
          ),
          isNull,
          reason: c,
        );
      }
      for (final c in bad) {
        expect(
          TextRules.remoteProblem(
            _update(EntityType.group, {GroupFields.currency: c}),
          ),
          isNotNull,
          reason: '$c',
        );
      }
    });

    test('money block currency', () {
      for (final c in good) {
        expect(
          TextRules.remoteProblem(
            _update(EntityType.expense, {ExpenseFields.money: _money(c)}),
          ),
          isNull,
          reason: c,
        );
      }
      for (final c in bad) {
        expect(
          TextRules.remoteProblem(
            _update(EntityType.expense, {ExpenseFields.money: _money(c)}),
          ),
          isNotNull,
          reason: '$c',
        );
      }
    });
  });

  // SECURITY-R5-01. The remote check now accepts any date from 1900 to
  // 9999, but the expense and payment editors open the date picker with
  // firstDate 2000 and lastDate next year and pass the stored date as
  // initialDate unchanged. showDatePicker asserts initialDate lies in that
  // range, so for an expense dated 1970 (what the remote check comment
  // itself says a phone with a reset clock writes), 1950 or 2090 (any key
  // holder may send one) tapping Date throws and the date cannot be fixed.
  for (final (what, date) in [
    ('1970 (a reset clock)', DateTime.utc(1970, 1, 1, 12)),
    ('1950 (a peer)', DateTime.utc(1950, 6, 1)),
    ('2090 (a peer)', DateTime.utc(2090, 6, 1)),
  ]) {
    testWidgets(
      'SECURITY-R5-01 the expense editor date picker opens for an expense '
      'dated $what',
      (tester) async {
        phoneView(tester);
        final w = await TestWorld.demo();
        await pumpApp(tester, w);
        final g = w.g.goa;
        final members = w.ledger.current.state.groups[g]!.members.keys.toList();
        final id = await w.ledger.addExpense(
          ExpenseDraft(
            groupId: g,
            description: 'Old',
            total: 100,
            currency: 'INR',
            paidBy: SplitSpec.single(members.first, 100),
            owedBy: SplitSpec.equal(members),
            category: 'food',
            date: date,
          ),
        );
        w.go(Routes.editExpense(id, groupId: g));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.calendar_today_rounded));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(DatePickerDialog), findsOneWidget);
      },
    );
  }

  testWidgets(
    'SECURITY-R5-01 the payment editor date picker opens for a payment '
    'dated 1970',
    (tester) async {
      phoneView(tester);
      final w = await TestWorld.demo();
      await pumpApp(tester, w);
      final g = w.g.goa;
      final members = w.ledger.current.state.groups[g]!.members.keys.toList();
      final id = await w.ledger.recordPayment(
        PaymentDraft(
          groupId: g,
          from: members[0],
          to: members[1],
          amount: 100,
          currency: 'INR',
          method: PaymentMethod.cash,
          date: DateTime.utc(1970, 1, 1, 12),
        ),
      );
      w.go(Routes.editExpense(id, groupId: g));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(S.date));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(DatePickerDialog), findsOneWidget);
    },
  );
}
