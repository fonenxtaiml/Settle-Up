// QA SECURITY round 4: an expense date the remote check accepts must not
// break the screens that show it (SECURITY-R4-01).
//
// TextRules lets a peer's expense carry any date with |ms| <= 8.64e15, the
// whole DateTime range. For a date in the first day of that range,
// DateTime.toLocal() and DateTime(y, m, d) throw ArgumentError in every
// time zone but UTC, so DateLabels.dayHeader throws inside the group
// screen's build. Run outside UTC to see it:
//   TZ=Asia/Kolkata flutter test test/qa/security/edge_date_render_test.dart
// In UTC (as CI runs) the first test passes, so the second one checks the
// remote check itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/router.dart';

import '../../ui/screens/screen_harness.dart';

void main() {
  const edge = -TextRules.maxDateMs;

  // After the fix the earliest date a peer may send is
  // TextRules.minModelDateMs (1900-01-01 UTC), not the start of the
  // DateTime range; the latest is TextRules.maxModelDateMs. Both must show
  // in any time zone:
  //   TZ=Asia/Kolkata flutter test test/qa/security/edge_date_render_test.dart
  for (final (what, ms) in [
    ('earliest', TextRules.minModelDateMs),
    ('latest', TextRules.maxModelDateMs),
  ])
    testWidgets(
      'SECURITY-R4-01 the group screen shows an expense at the $what date a '
      'peer may send',
      (tester) async {
        phoneView(tester);
        final w = await TestWorld.demo();
        await pumpApp(tester, w);
        final g = w.g.goa;
        final members = w.ledger.current.state.groups[g]!.members.keys.toList();
        await w.ledger.addExpense(
          ExpenseDraft(
            groupId: g,
            description: 'Edge',
            total: 100,
            currency: 'INR',
            paidBy: SplitSpec.single(members.first, 100),
            owedBy: SplitSpec.equal(members),
            category: 'food',
            date: utcFromMillis(ms),
          ),
        );
        w.go(Routes.group(g));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Edge'), findsOneWidget);
      },
    ); // SECURITY-R4-01

  test('the remote check refuses a date that has no local calendar day', () {
    // Local offsets run from -12 h to +14 h. Within 14 h of the start of
    // the DateTime range the local day is not a DateTime, so no phone
    // outside UTC can show such a date.
    for (final ms in [edge, edge + 3600000, edge + 14 * 3600000]) {
      final op = Operation(
        id: 'edge',
        groupId: 'g',
        deviceId: 'd',
        counter: 1,
        hlc: const Hlc(1, 0, 'd'),
        entityType: EntityType.expense,
        entityId: 'e',
        kind: OpKind.update,
        payload: {ExpenseFields.date: ms},
      );
      expect(TextRules.remoteProblem(op), isNotNull, reason: '$ms');
    }
  });
}
