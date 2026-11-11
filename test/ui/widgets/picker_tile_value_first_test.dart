// PickerTile puts the value first (VISUAL-R17-01): a wide leading (a
// currency symbol at large text) takes only what the value can spare and
// scales down in it, so the currency tile of New group, Edit group and
// onboarding shows "<name> (<code>)" whole, with the whole symbol beside
// it, for every currency at every text size and phone width. Real fonts.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart' show loadRealFonts;

Future<void> _pump(WidgetTester t, Currency c, {bool dark = false}) =>
    t.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              padding: const EdgeInsets.symmetric(horizontal: Space.screen),
              children: [
                PickerTile(
                  label: 'Currency',
                  value: '${c.name} (${c.code})',
                  leading: SymbolText(
                    c.symbol,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxWidth: SymbolText.maxLeadingWidth(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

RenderParagraph _paragraph(WidgetTester t, String text) =>
    t.renderObject<RenderParagraph>(
      find
          .descendant(of: find.text(text), matching: find.byType(RichText))
          .first,
    );

void main() {
  setUpAll(loadRealFonts);

  for (final width in const [320.0, 360.0, 412.0]) {
    for (final scale in const [1.0, 1.3, 1.5, 2.0]) {
      testWidgets('${width.toInt()} dp at ${scale}x: every currency shows its '
          'name and code whole beside the whole symbol', (t) async {
        t.view.physicalSize = Size(width, 800) * 3;
        t.view.devicePixelRatio = 3;
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearAllTestValues);
        final cut = <String>[];
        for (final c in Currencies.all) {
          await _pump(t, c, dark: c.code.hashCode.isOdd);
          final value = '${c.name} (${c.code})';
          if (_paragraph(t, value).didExceedMaxLines) cut.add(c.code);
          // The symbol is one line, never cut: it scales down instead.
          expect(_paragraph(t, c.symbol).didExceedMaxLines, isFalse);
          expect(t.takeException(), isNull, reason: c.code);
        }
        expect(cut, isEmpty);
      });
    }
  }

  testWidgets('a symbol keeps its own size when the value has room', (t) async {
    t.view.physicalSize = const Size(412, 800) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final sos = Currencies.of('SOS');
    await _pump(t, sos);
    // No FittedBox scaling: the symbol is drawn at its natural width.
    final text = t.getSize(find.text(sos.symbol));
    final box = t.getSize(
      find.ancestor(
        of: find.text(sos.symbol),
        matching: find.byType(FittedBox),
      ),
    );
    expect(box.width, closeTo(text.width, 0.5));
  });

  testWidgets('an avatar or icon leading keeps its 26 dp slot', (t) async {
    t.view.physicalSize = const Size(320, 800) * 3;
    t.view.devicePixelRatio = 3;
    t.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearAllTestValues);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.symmetric(horizontal: Space.screen),
            child: PickerTile(
              label: 'Paid by',
              value: 'Priya and two other people paid',
              leading: Icon(Icons.group_outlined, size: 20),
            ),
          ),
        ),
      ),
    );
    final slot = t.getSize(
      find
          .ancestor(
            of: find.byIcon(Icons.group_outlined),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );
    expect(slot.width, 26);
    expect(t.takeException(), isNull);
  });
}
