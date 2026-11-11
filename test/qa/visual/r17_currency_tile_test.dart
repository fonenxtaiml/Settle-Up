// QA VISUAL round 17: the VISUAL-R15-01 fix lets the currency PickerTile's
// leading slot grow to a quarter of the screen for a long symbol
// (lib/ui/widgets/form_tiles.dart, PickerTile; SymbolText.maxLeadingWidth).
// On New group and Edit group the value beside it, "<name> (<code>)", is
// capped at two lines with an ellipsis, so at 2.0x the wider symbol now
// pushes the currency code behind the ellipsis for currencies whose value
// fit before the fix ("Somali shilling (S…", "Macanese pataca (M…").
//
// Tests named "QA VISUAL-R17-NN" with `skip: true` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;

/// Pumps the currency tile the way New group and Edit group build it
/// (inside the 20 dp gutter) and says whether its value was cut.
Future<bool> _valueCut(
  WidgetTester t,
  Currency c, {
  required bool reference,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.screen),
            child: PickerTile(
              label: 'Currency',
              value: '${c.name} (${c.code})',
              // The reference is the 26 dp slot an avatar takes.
              leading: reference
                  ? const SizedBox(width: 26)
                  : SymbolText(
                      c.symbol,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxWidth: SymbolText.maxLeadingWidth(context),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  final p = t.renderObject<RenderParagraph>(
    find
        .descendant(
          of: find.text('${c.name} (${c.code})'),
          matching: find.byType(RichText),
        )
        .first,
  );
  return p.didExceedMaxLines;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'QA VISUAL-R17-01: a long currency symbol does not push the currency '
    'code behind the ellipsis on the New group and Edit group currency tile',
    (t) async {
      final problems = <String>[];
      for (final width in const [320.0, 360.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          t.view.physicalSize = Size(width, 640) * 3;
          t.view.devicePixelRatio = 3;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          final cut = <String>[];
          for (final c in Currencies.all) {
            if (await _valueCut(t, c, reference: false) &&
                !await _valueCut(t, c, reference: true)) {
              cut.add(c.code);
            }
          }
          if (cut.isNotEmpty) {
            problems.add(
              '${width.toInt()} dp ${scale}x: ${cut.length} '
              '(${cut.join(' ')})',
            );
          }
        }
      }
      t.view.reset();
      t.platformDispatcher.clearAllTestValues();
      expect(problems, isEmpty);
    },
    // QA VISUAL-R17-01: a long currency symbol pushes the currency code
    // behind the ellipsis on the New group, Edit group and onboarding
    // currency tile at 2.0x.
    skip: true,
  );
}
