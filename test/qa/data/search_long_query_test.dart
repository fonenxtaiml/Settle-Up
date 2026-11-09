// QA DATA-R2: the Search screen after the DATA-R1-09 change. A long query
// with no results is shortened in the headline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../uiflow/real_harness.dart';

void main() {
  testWidgets(
    'a no-results query over 40 characters with an emoji at the cut does '
    'not break the headline',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      await w.seedGroup(people: const ['Priya']);
      await pumpReal(tester, w, location: Routes.home);
      await qaTap(tester, find.byTooltip(S.searchExpenses));
      expect(w.location, Routes.search);
      // 38 letters then emoji: _shortQuery keeps 39 UTF-16 units, which
      // ends in the first half of a surrogate pair.
      final q = '${'x' * 38}\u{1F695}\u{1F695}';
      await tester.enterText(find.byType(TextField).first, q);
      await qaSettle(tester);
      // Expected: the headline renders (cut on a character boundary).
      // Today the paragraph builder throws "string is not well-formed
      // UTF-16" while laying out the headline.
      expect(tester.takeException(), isNull);
      expect(find.textContaining('x' * 38), findsWidgets);
      await w.shutdown(tester);
    },
    // QA DATA-R2-02: _shortQuery splits a surrogate pair.
    skip: true,
  );
}
