// VISUAL-R11-02 regression: the date picker's text passes
// textContrastGuideline in both themes, in every state it can be in, not
// only the year list: the calendar, the year list, input mode, an input
// error and the input-only picker of a 320 dp phone. Each text is also
// checked by hand against the dialog surface at 4.5:1 (3:1 for large text),
// so a colour the guideline's sampling misses is still caught.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/common.dart';

import 'kit_harness.dart' show loadRealFonts;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Future<void> _open(WidgetTester t, Size size, Brightness b) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  // A fresh tree: the stock input field asserts when the theme above an
  // open picker changes, which a new MaterialApp would do.
  await t.pumpWidget(const SizedBox.shrink());
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: b == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  pickEntryDate(
    ctx,
    initial: DateTime(2026, 11, 9),
    now: DateTime(2026, 11, 10),
  ).ignore();
  await t.pumpAndSettle();
}

/// Every enabled text in the dialog against the dialog's surface.
List<String> _byHand(WidgetTester t, String where) {
  final out = <String>[];
  final surface = t.widget<Material>(_inDialog(find.byType(Material)).first);
  for (final e in _inDialog(find.byType(RichText)).evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    final text = p.text.toPlainText();
    if (text.trim().isEmpty) continue;
    // Skip text a parent hides; text on its own fill (the chosen day, the
    // chosen year) is checked against that fill.
    var hidden = false;
    for (RenderObject? o = p; o != null; o = o.parent) {
      if (o is RenderOpacity && o.opacity == 0 ||
          o is RenderAnimatedOpacity && o.opacity.value == 0) {
        hidden = true;
      }
    }
    Color? fill;
    e.visitAncestorElements((a) {
      final w = a.widget;
      final d = w is Ink
          ? w.decoration
          : w is DecoratedBox
          ? w.decoration
          : null;
      final c = d is BoxDecoration
          ? d.color
          : d is ShapeDecoration
          ? d.color
          : null;
      if (c != null && c.a > 0.5) fill = c;
      return fill == null && w is! DatePickerDialog;
    });
    if (hidden) continue;
    p.text.visitChildren((span) {
      final style = span.style ?? p.text.style;
      final color = style?.color;
      if (color == null || color.a < 0.5) return true; // disabled days
      final size = p.textScaler.scale(style!.fontSize ?? 14);
      final bold = (style.fontWeight ?? FontWeight.w400).value >= 700;
      final large = size >= 24 || (bold && size >= 18.66);
      final r = _contrast(color, fill ?? surface.color!);
      if (r < (large ? 3.0 : 4.5)) {
        out.add('$where: "$text" is ${r.toStringAsFixed(2)}:1');
      }
      return true;
    });
  }
  return out;
}

void main() {
  testWidgets('every state of the picker meets the contrast guideline', (
    t,
  ) async {
    await t.runAsync(loadRealFonts);
    addTearDown(t.view.reset);
    final handle = t.ensureSemantics();
    final problems = <String>[];
    Future<void> check(String where) async {
      final r = await textContrastGuideline.evaluate(t);
      if (!r.passed) {
        problems.add('$where: ${r.reason}');
      }
      problems.addAll(_byHand(t, where));
    }

    for (final b in Brightness.values) {
      // A 360 dp phone: the calendar, its year list, input mode and an
      // input error.
      await _open(t, const Size(360, 640), b);
      final at = '360 ${b.name}';
      expect(_inDialog(find.byType(CalendarDatePicker)), findsOneWidget);
      await check('$at calendar');
      await t.tap(find.text('November 2026'));
      await t.pumpAndSettle();
      await check('$at years');
      await t.tap(find.text('2026'));
      await t.pumpAndSettle();
      await t.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
      await t.pumpAndSettle();
      await check('$at input');
      await t.enterText(_inDialog(find.byType(TextField)), '31/02/2026');
      await t.tap(_inDialog(find.text('OK')));
      await t.pumpAndSettle();
      expect(_inDialog(find.text('Invalid format.')), findsOneWidget);
      // The error line is checked by hand only. textContrastGuideline
      // samples a 1 px per dp capture, where this 13 dp line in the light
      // theme is mostly anti-aliased edge: the most frequent dark pixel is a
      // blend (#CE726D, 12 px) a pixel ahead of the error colour itself
      // (#B3261E, 11 px), which is 6.5:1 on the white surface.
      problems.addAll(_byHand(t, '$at input error'));
      // A 320 dp phone: input only.
      await _open(t, const Size(320, 568), b);
      expect(_inDialog(find.byType(CalendarDatePicker)), findsNothing);
      await check('320 ${b.name} input only');
      // The field, filled with the dialog's own surface, has its outline.
      final scheme = Theme.of(t.element(_dialog)).colorScheme;
      final deco = t
          .widget<InputDecorator>(_inDialog(find.byType(InputDecorator)))
          .decoration;
      expect(deco.fillColor, scheme.surfaceContainerLowest);
      expect(deco.enabledBorder?.borderSide.color, scheme.outline);
      await t.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
