// QA VISUAL round 15: the currency picker (New group, Edit group, the
// expense editor's symbol and Settings > Home currency) puts each symbol
// in a fixed 40 dp leading box with an ellipsis, so with the bundled
// Familjen Grotesk "MOP$" and "Sh.So." are cut at the default text size,
// 11 symbols at 1.3x and 56 at 2.0x, among them "KD", "AED", "CHF" and
// "HK$" (lib/ui/screens/pickers.dart, _CurrencySheetState.build).
//
// Tests named "QA VISUAL-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/pickers.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;

/// The symbols the picker's first row (the selected currency) cuts, for
/// every currency, at [scale] on a 360 dp phone.
Future<List<String>> _cutSymbols(WidgetTester t, double scale) async {
  t.view.physicalSize = const Size(360, 640) * 3;
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final cut = <String>[];
  for (final c in Currencies.all) {
    pickCurrency(ctx, selected: c.code).ignore();
    await t.pumpAndSettle();
    final symbol = find.descendant(
      of: find.byType(ListTile).first,
      matching: find.text(c.symbol),
    );
    final p = t.renderObject<RenderParagraph>(
      find.descendant(of: symbol.first, matching: find.byType(RichText)).first,
    );
    if (p.didExceedMaxLines ||
        p.getMaxIntrinsicWidth(double.infinity) > p.size.width + 0.5) {
      cut.add(c.symbol);
    }
    Navigator.of(ctx).pop();
    await t.pumpAndSettle();
  }
  return cut;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'QA VISUAL-R15-01: the currency picker shows every symbol whole at '
    '1.0x, 1.3x and 2.0x',
    // QA VISUAL-R15-01: Currency picker cuts symbols in its 40 dp box.
    skip: true,
    (tester) async {
      final problems = <String>[];
      for (final scale in const [1.0, 1.3, 2.0]) {
        final cut = await _cutSymbols(tester, scale);
        if (cut.isNotEmpty) {
          problems.add('${scale}x: ${cut.length} cut (${cut.join(' ')})');
        }
      }
      expect(problems, isEmpty);
    },
  );
}
