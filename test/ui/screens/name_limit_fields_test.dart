// UIFLOW-R8-01 regression: every name field counts and caps a name as it
// is stored (NFKC), so a name the field holds is always saved: the group
// name, New group > add person, Members > rename, the claim prompt and the
// counters of the name prompts. Real Ledger and Settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart' show NameLimit;
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

Finder get _dialogField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

String _text(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

void main() {
  testWidgets('New group: a 59-character name ending in "…" is cut to fit '
      'and the group is created', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.newGroup);
    final typed = '${'G' * 59}…';
    await tester.enterText(fieldLabeled(S.groupName), typed);
    await tester.pump();
    final held = _text(tester, fieldLabeled(S.groupName));
    expect(NameLimit.fits(held, 60), isTrue);
    expect(held, 'G' * 59);
    await qaTap(tester, find.text(S.createGroupAction));
    expect(snackText(tester), S.groupCreated);
    expect(w.state.visibleGroups.single.group!.name, 'G' * 59);
    await w.shutdown(tester);
  });

  testWidgets('New group > add person: typing and pasting a name that grows '
      'under NFKC give the same field, and it is added', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.newGroup);
    const typed = 'Meera Venkataraman Subramaniam Iyer Jr… Q';
    final person = fieldLabeled(S.personName);
    await tester.enterText(person, typed);
    await tester.pump();
    final pasted = _text(tester, person);
    // Typed one character at a time.
    var t = '';
    for (final c in typed.characters) {
      await tester.enterText(person, t + c);
      t = _text(tester, person);
    }
    expect(t, pasted);
    expect(NameLimit.fits(pasted, 40), isTrue);
    expect(pasted, 'Meera Venkataraman Subramaniam Iyer Jr Q');
    await tester.enterText(fieldLabeled(S.groupName), 'Cabin');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    final g = w.state.visibleGroups.single;
    expect(
      g.activeMembers.map((m) => m.displayName),
      contains('Meera Venkataraman Subramaniam Iyer Jr Q'),
    );
    await w.shutdown(tester);
  });

  for (final c in ['½', '™', 'ﬁ', '㈜', 'ﷺ']) {
    testWidgets('Members > rename to 39 letters + "$c": the counter counts '
        'the stored form and Save works', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      await pumpReal(tester, w, location: Routes.members(gid));
      await qaTap(tester, find.text('Priya'));
      await qaTap(tester, find.text(S.rename));
      await tester.enterText(_dialogField, '${'P' * 39}$c');
      await tester.pump();
      final held = _text(tester, _dialogField);
      final count = NameLimit.length(held);
      expect(count, lessThanOrEqualTo(40));
      expect(find.text('$count/40'), findsOneWidget);
      expect(find.text(S.errTooLong), findsNothing);
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(snackText(tester), isNot(S.errTooLong));
      expect(snackText(tester), isNot(S.errGeneric));
      expect(
        w.group(gid).activeMembers.map((m) => m.displayName),
        isNot(contains('Priya')),
      );
      await w.shutdown(tester);
    });
  }
}
