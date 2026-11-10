// QA DATA-R3: reverify DATA-R2-02. The "No expenses match" headline
// shortens a long query on character boundaries for every kind of
// character that spans more than one UTF-16 unit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../uiflow/real_harness.dart';

void main() {
  testWidgets('long no-results queries are cut on character boundaries', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup(people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    await qaTap(tester, find.byTooltip(S.searchExpenses));
    expect(w.location, Routes.search);

    const family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
    const flag = '\u{1F1EE}\u{1F1F3}';
    const taxi = '\u{1F695}';
    final cases = <String, String>{
      // The original repro.
      '${'x' * 38}$taxi$taxi': '${'x' * 38}$taxi$taxi',
      // One past the limit: 39 kept, then the ellipsis.
      '${'x' * 38}$taxi$taxi$taxi': '${'x' * 38}$taxi…',
      // A ZWJ family (8 units) right at the cut stays whole or goes whole.
      '${'x' * 38}$family${'y' * 2}': '${'x' * 38}$family…',
      // Flags are two regional indicators.
      '$flag' * 41: '${'$flag' * 39}…',
      // Devanagari clusters (consonant + virama + consonant).
      'क्ष' * 41: '${'क्ष' * 39}…',
      // Exactly 40 characters of emoji: not cut at all.
      taxi * 40: taxi * 40,
    };
    for (final MapEntry(key: q, value: shown) in cases.entries) {
      await tester.enterText(find.byType(TextField).first, q);
      await qaSettle(tester);
      expect(tester.takeException(), isNull, reason: q);
      expect(find.text(S.searchNone(shown)), findsOneWidget, reason: q);
    }
    await w.shutdown(tester);
  });
}
