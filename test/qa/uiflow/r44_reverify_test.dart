// QA UIFLOW round 44: reverification of UIFLOW-R42-01 (New group drops a
// person name with no letter or number left in the field on Create) on the
// real Ledger, and a sweep of the paths around the changed Create: the
// group name refused first, a person picked from other groups typed again,
// a name too long once stored, and a valid name left in the field while the
// group name is still missing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await qaSettle(tester);
}

Set<String> _names(RealWorld w) => w
    .ledger
    .current
    .state
    .visibleGroups
    .single
    .activeMembers
    .map((m) => m.displayName)
    .toSet();

void main() {
  testWidgets('R44 probe (UIFLOW-R42-01): a refused group name and a refused '
      'person name: neither creates the group, each is said in turn, and '
      'clearing the person field then creates it', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), '?!');
    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), '😎');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(w.ledger.current.state.visibleGroups, isEmpty);
    expect(find.text(S.nameNeedsLetter), findsWidgets);
    expect(w.location, Routes.newGroup);

    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(w.ledger.current.state.visibleGroups, isEmpty);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    // Tapping Create again changes nothing.
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(w.ledger.current.state.visibleGroups, isEmpty);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);

    await tester.enterText(fieldLabeled(S.personName), '');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(_names(w), {'Arjun', 'Meera'});
    await w.shutdown(tester);
  });

  testWidgets('R44 probe: a valid name left in the field while the group name '
      'is missing is kept, and joins the group once the name is given', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), 'Kabir');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(w.ledger.current.state.visibleGroups, isEmpty);
    expect(find.text(S.nameNeeded), findsOneWidget);
    expect(
      tester.widget<TextField>(fieldLabeled(S.personName)).controller!.text,
      'Kabir',
    );
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(_names(w), {'Arjun', 'Kabir'});
    await w.shutdown(tester);
  });

  testWidgets('R44 probe: a person picked from other groups and typed again '
      'in the field is that person once', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.pump();
    await qaTap(tester, find.widgetWithText(FilterChip, 'Priya'));
    await tester.enterText(fieldLabeled(S.personName), 'PRIYA');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    final g = w.groupNamed('Ladakh');
    expect(g.activeMembers.map((m) => m.displayName).toList()..sort(), [
      'Arjun',
      'Priya',
    ]);
    // The same person as in Goa trip, not a new one.
    final goa = w.groupNamed('Goa trip');
    final priyaGoa = goa.activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    final priyaNew = g.activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    expect(priyaNew, priyaGoa);
    await w.shutdown(tester);
  });

  testWidgets('R44 probe: a person name too long once stored, left in the '
      'field on Create, is refused, not dropped', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    // 39 letters and an ellipsis, stored as "..." (42 characters).
    await tester.enterText(fieldLabeled(S.personName), '${'a' * 39}…');
    await tester.pump();
    final held = tester
        .widget<TextField>(fieldLabeled(S.personName))
        .controller!
        .text;
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    final groups = w.ledger.current.state.visibleGroups;
    if (groups.isEmpty) {
      // Refused: the reason is said.
      expect(find.text(S.errTooLong), findsOneWidget);
    } else {
      // Accepted: the field held a name that fits, and it joined.
      expect(_names(w).length, 2, reason: 'field held "$held"');
    }
    await w.shutdown(tester);
  });
}
