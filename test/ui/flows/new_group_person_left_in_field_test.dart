// UIFLOW-R42-01: whatever is left in New group's Person name field when
// Create is tapped is handled the way Add person and the keyboard's Done
// handle it. A name joins the group; a repeat of a name already in the
// list (yours included) is that person, once; text that is no name (no
// letter or number once normalised) is refused with "Use at least one
// letter or number", the group is not created and the text stays in the
// field so the user can fix it or clear it. No person is ever left out
// without a word.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

/// Characters with no letter or number, one list per class: punctuation
/// (P*), symbols and emoji (S*), spaces (Z*) and format characters (Cf),
/// and the fillers that draw a blank.
const _classes = <String, List<String>>{
  'punctuation': [
    '?',
    '!',
    '-',
    '.',
    ',',
    '¿',
    '‽',
    '—',
    '–',
    '«',
    '»',
    '(',
    ')',
    '_',
    '・',
  ],
  'symbols': [
    '😎',
    '🍕',
    '❤️',
    '+',
    '=',
    '₹',
    r'$',
    '©',
    '★',
    '→',
    '∑',
    '^',
    '|',
    '~',
  ],
  'spaces': [' ', '\u00A0', '\u2003', '\u3000', '\u202F', '\u205F'],
  'format': [
    '\u200B',
    '\u200C',
    '\u200D',
    '\u200E',
    '\u200F',
    '\u2060',
    '\u00AD',
    '\u202A',
    '\u202E',
    '\u2066',
    '\u2069',
    '\uFEFF',
  ],
  'fillers': ['\u3164', '\u1160', '\u115F', '\uFFA0', '\u2800'],
};

/// [count] seeded random texts drawn from every class above, each with at
/// least one character that Dart's trim keeps (so the field is not empty).
List<String> _noNames(int count, int seed) {
  final rnd = Random(seed);
  final all = [for (final c in _classes.values) ...c];
  final kept = [
    for (final c in all)
      if (c.trim().isNotEmpty) c,
  ];
  return [
    for (var i = 0; i < count; i++)
      [
        for (var j = rnd.nextInt(4); j > 0; j--) all[rnd.nextInt(all.length)],
        kept[rnd.nextInt(kept.length)],
        for (var j = rnd.nextInt(4); j > 0; j--) all[rnd.nextInt(all.length)],
      ].join(),
  ];
}

String _show(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

Future<RealWorld> _openNewGroup(WidgetTester tester) async {
  qaPhone(tester);
  final w = await RealWorld.create(name: 'Arjun');
  await pumpReal(tester, w);
  w.push(Routes.newGroup);
  await qaSettle(tester);
  await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
  await tester.enterText(fieldLabeled(S.personName), 'Meera');
  await tester.pump();
  await qaTap(tester, find.text(S.addPerson));
  return w;
}

Future<void> _create(WidgetTester tester) async {
  await qaTap(tester, find.text(S.createGroupAction));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await qaSettle(tester);
}

Set<String> _members(RealWorld w) => w.state.visibleGroups.single.activeMembers
    .map((m) => m.displayName)
    .toSet();

void main() {
  test('the generated texts are no names (premise)', () {
    for (final t in _noNames(200, 4201)) {
      expect(t.trim(), isNotEmpty, reason: _show(t));
      expect(
        nameInputError(t, limit: kMemberNameMax),
        S.nameNeedsLetter,
        reason: _show(t),
      );
    }
  });

  testWidgets('UIFLOW-R42-01: Create refuses every text with no letter or '
      'number left in the person field, then creates once it is cleared', (
    tester,
  ) async {
    final w = await _openNewGroup(tester);
    final texts = [
      for (final c in _classes.values)
        for (final ch in c)
          if (ch.trim().isNotEmpty) ch,
      ..._noNames(24, 4202),
    ];
    for (final t in texts) {
      await tester.enterText(fieldLabeled(S.personName), t);
      await tester.pump();
      await _create(tester);
      expect(
        w.state.visibleGroups,
        isEmpty,
        reason: 'created with "${_show(t)}" dropped',
      );
      expect(find.text(S.nameNeedsLetter), findsOneWidget, reason: _show(t));
      expect(w.location, Routes.newGroup, reason: _show(t));
      expect(
        tester.widget<TextField>(fieldLabeled(S.personName)).controller!.text,
        t,
        reason: 'the text stays in the field: ${_show(t)}',
      );
    }
    await tester.enterText(fieldLabeled(S.personName), '');
    await tester.pump();
    await _create(tester);
    expect(_members(w), {'Arjun', 'Meera'});
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R42-01: a refused text fixed with a letter joins the '
      'group on Create', (tester) async {
    final w = await _openNewGroup(tester);
    await tester.enterText(fieldLabeled(S.personName), '😎');
    await tester.pump();
    await _create(tester);
    expect(w.state.visibleGroups, isEmpty);
    await tester.enterText(fieldLabeled(S.personName), 'Kabir 😎');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await _create(tester);
    expect(_members(w), {'Arjun', 'Meera', 'Kabir 😎'});
    await w.shutdown(tester);
  });

  for (final repeat in const ['meera', 'ARJUN', 'Mee\u00ADra']) {
    testWidgets('UIFLOW-R42-01: a repeat ("${_show(repeat)}") left in the '
        'field is that person, once', (tester) async {
      final w = await _openNewGroup(tester);
      await tester.enterText(fieldLabeled(S.personName), repeat);
      await tester.pump();
      await _create(tester);
      expect(_members(w), {'Arjun', 'Meera'});
      expect(w.state.visibleGroups.single.activeMembers, hasLength(2));
      await w.shutdown(tester);
    });
  }

  testWidgets('UIFLOW-R42-01: only spaces left in the field is an empty '
      'field', (tester) async {
    final w = await _openNewGroup(tester);
    await tester.enterText(fieldLabeled(S.personName), '   ');
    await tester.pump();
    await _create(tester);
    expect(_members(w), {'Arjun', 'Meera'});
    await w.shutdown(tester);
  });
}
