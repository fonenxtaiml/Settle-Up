// Currency symbols are shown whole everywhere they lead a row
// (VISUAL-R15-01): the currency picker's symbol column fits every symbol,
// with the same width on every row, and the currency PickerTile of New
// group, Edit group and onboarding grows for a long symbol instead of
// wrapping it in its 26 dp slot. Real fonts, every currency, 1.0x to 2.0x.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/pickers.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart' show loadRealFonts;

const _scales = [1.0, 1.3, 1.5, 2.0];

void _phone(WidgetTester t, double scale, {double width = 360}) {
  t.view.physicalSize = Size(width, 640) * 3;
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

/// Whether [p] shows its whole text on one line.
bool _whole(RenderParagraph p) =>
    !p.didExceedMaxLines &&
    p.getMaxIntrinsicWidth(double.infinity) <= p.size.width + 0.5 &&
    // One line: no taller than the text laid out with no width limit.
    p.size.height <= p.getMinIntrinsicHeight(double.infinity) + 0.5;

RenderParagraph _paragraph(WidgetTester t, Finder text) =>
    t.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)).first,
    );

void main() {
  setUpAll(loadRealFonts);

  for (final scale in _scales) {
    testWidgets('picker at ${scale}x: every symbol is whole and the names '
        'line up', (t) async {
      _phone(t, scale);
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
      final starts = <double>{};
      var seen = 0;
      // The selected currency is the first row: open the picker on each.
      for (final c in Currencies.all) {
        pickCurrency(ctx, selected: c.code).ignore();
        await t.pumpAndSettle();
        final tiles = find.byType(ListTile);
        final symbol = find.descendant(
          of: tiles.first,
          matching: find.text(c.symbol),
        );
        if (!_whole(_paragraph(t, symbol.first))) cut.add(c.symbol);
        for (final i in [0, 1]) {
          final title = find.descendant(
            of: tiles.at(i),
            matching: find.byType(RichText),
          );
          // The symbol, then the name.
          starts.add(t.getTopLeft(title.at(1)).dx.roundToDouble());
        }
        seen++;
        Navigator.of(ctx).pop();
        await t.pumpAndSettle();
      }
      expect(seen, Currencies.all.length);
      expect(cut, isEmpty);
      expect(starts, hasLength(1), reason: 'names start at one x');
    });
  }

  testWidgets('picker at 1.0x: no symbol is scaled down', (t) async {
    _phone(t, 1.0);
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
    for (final code in ['MOP', 'SOS', 'KWD', 'AED', 'CHF', 'HKD']) {
      pickCurrency(ctx, selected: code).ignore();
      await t.pumpAndSettle();
      final c = Currencies.of(code);
      final fitted = find.ancestor(
        of: find.text(c.symbol).first,
        matching: find.byType(FittedBox),
      );
      final box = t.renderObject<RenderBox>(fitted.first);
      final p = _paragraph(t, find.text(c.symbol).first);
      expect(
        box.size.width,
        greaterThanOrEqualTo(p.size.width - 0.5),
        reason: '${c.symbol} was scaled down',
      );
      Navigator.of(ctx).pop();
      await t.pumpAndSettle();
    }
  });

  for (final scale in _scales) {
    testWidgets('currency PickerTile at ${scale}x shows every symbol whole '
        'on one line', (t) async {
      _phone(t, scale);
      final cut = <String>[];
      final shrunk = <String>[];
      for (final c in Currencies.all) {
        await t.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: PickerTile(
                    label: 'Currency',
                    value: '${c.name} (${c.code})',
                    leading: SymbolText(
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
        final p = _paragraph(t, find.text(c.symbol));
        if (!_whole(p)) cut.add(c.symbol);
        // Up to 1.3x every symbol fits at its own size: none is shrunk
        // into the 26 dp slot an avatar takes.
        final box = t.renderObject<RenderBox>(
          find.ancestor(
            of: find.text(c.symbol),
            matching: find.byType(FittedBox),
          ),
        );
        if (scale <= 1.3 && box.size.width < p.size.width - 0.5) {
          shrunk.add(c.symbol);
        }
      }
      expect(cut, isEmpty);
      expect(shrunk, isEmpty);
    });
  }

  testWidgets('PickerTile keeps a 26 dp slot for an avatar or icon', (t) async {
    _phone(t, 1.0);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: PickerTile(
            label: 'Date',
            value: 'Today',
            leading: Icon(Icons.event, size: 20),
          ),
        ),
      ),
    );
    final slot = find.ancestor(
      of: find.byType(Icon),
      matching: find.byType(Center),
    );
    expect(t.getSize(slot.first).width, 26);
  });
}
