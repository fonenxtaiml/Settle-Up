// DATA-R6-02: a name with no letter or number is refused where it is
// typed (onboarding, Edit name, the phone name, a new group, a person),
// with the "Use at least one letter or number" message, and nothing is
// saved; the same text with a letter in it is saved in its normalised form.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

/// Names that show nothing: the DATA-R6-02 repro characters and the
/// neighbouring classes (soft hyphen, word joiner, bidi marks, a Hangul
/// filler between spaces, symbols only).
const _blanks = [
  '\u200B',
  '\u3164',
  '\u2800',
  '\u{E0020}',
  '\u115F',
  '\uFFA0',
  '\u00AD',
  '\u2060',
  '\u200E\u200F',
  ' \u3164 ',
  '-',
  '...',
  '\u{1F355}',
];

String _show(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

FilledButton _dialogSave(WidgetTester tester) => tester.widget<FilledButton>(
  find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  ),
);

void main() {
  test('nameInputError: no message for an empty field or a name', () {
    expect(nameInputError(''), isNull);
    expect(nameInputError('   '), isNull);
    expect(nameInputError('Priya'), isNull);
    expect(nameInputError('\u3164Priya\u2800'), isNull);
    expect(nameInputError('7'), isNull);
    for (final b in _blanks) {
      expect(nameInputError(b), S.nameNeedsLetter, reason: _show(b));
    }
  });

  testWidgets('onboarding: Get started stays off for a name that shows '
      'nothing, and says why', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    expect(w.location, Routes.onboarding);
    for (final b in _blanks) {
      await tester.enterText(find.byType(TextField).first, b);
      await tester.pump();
      expect(filledButton(tester, S.getStarted).onPressed, isNull,
          reason: _show(b));
      expect(find.text(S.nameNeedsLetter), findsOneWidget, reason: _show(b));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await qaSettle(tester);
      expect(w.settings.profile, isNull, reason: _show(b));
    }
    await onboardThroughUi(tester, '\u3164Arjun\u2800K\u200B');
    expect(w.settings.profile!.displayName, 'Arjun K');
    expect(w.location, Routes.home);
    // The phone can start a group with that name (DATA-R6-02).
    await w.seedGroup();
    await w.shutdown(tester);
  });

  testWidgets('Edit name: Save stays off for a name that shows nothing, so '
      'the profile and my members keep my name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final g = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun').first);
    for (final b in _blanks) {
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        b,
      );
      await tester.pump();
      expect(_dialogSave(tester).onPressed, isNull, reason: _show(b));
      expect(find.text(S.nameNeedsLetter), findsOneWidget, reason: _show(b));
    }
    await qaTap(tester, find.text(S.cancel));
    expect(w.settings.profile!.displayName, 'Arjun');
    expect(
      w.group(g).memberForPerson(w.settings.profile!.personId)!.displayName,
      'Arjun',
    );
    await w.shutdown(tester);
  });

  testWidgets('phone name: Save stays off for a name that shows nothing',
      (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.phoneName));
    for (final b in ['\u200B', '\u3164', '\u2800', '\u{E0020}']) {
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        b,
      );
      await tester.pump();
      expect(_dialogSave(tester).onPressed, isNull, reason: _show(b));
    }
    await qaTap(tester, find.text(S.cancel));
    expect(w.settings.device.deviceName, 'Pixel 8');
    await w.shutdown(tester);
  });

  testWidgets('new group: a group name or person that shows nothing is '
      'refused with the message', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, find.text(S.createGroup).last);
    expect(w.location, Routes.newGroup);
    await tester.enterText(fieldLabeled(S.groupName), '\u3164');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await qaTap(tester, find.text(S.createGroupAction).last);
    expect(w.state.visibleGroups, isEmpty);
    await tester.enterText(fieldLabeled(S.groupName), 'Goa trip');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await tester.enterText(fieldLabeled(S.personName), '\u2800');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await qaSettle(tester);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await w.shutdown(tester);
  });
}
