// QA VISUAL round 11: reverification of the round 10 date picker fix
// (VISUAL-R10-01 header overflow, VISUAL-R10-02 day cells under 48 dp)
// over the whole class, and a regression sweep of the picker as the
// editors now open it: input only on 320 dp phones and at 2.0x text on
// 360 dp phones, with the keyboard up, and in the dark theme.
//
// Tests named "QA VISUAL-R11-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'visual_harness.dart';

Variant _v(double w, double scale, [Brightness b = Brightness.light]) =>
    (size: Size(w, w <= 320 ? 568 : 640), scale: scale, brightness: b);

SemanticsNode? _node(WidgetTester tester, Pattern label) {
  final all = find.semantics.byLabel(label).evaluate().toList();
  return all.isEmpty ? null : all.first;
}

Finder _vertical() => find.byWidgetPredicate(
  (w) =>
      w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical,
);

/// Semantic tap on the first node whose label matches [label], scrolling
/// the page until it is built.
Future<bool> _semanticTap(WidgetTester tester, Pattern label) async {
  for (var i = 0; i < 12 && _node(tester, label) == null; i++) {
    final s = _vertical();
    if (s.evaluate().isEmpty) break;
    final pos = tester.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (_node(tester, label) == null) return false;
  tester.semantics.tap(find.semantics.byLabel(label).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return true;
}

/// Settle up: Priya pays me, the form with its Date row.
String _settle(VisualWorld w) {
  final gs = w.phone.gs(w.group);
  final me = gs.members.values.firstWhere((m) => m.personId == w.phone.me);
  final f = gs.members.values.firstWhere(
    (m) => m.displayName == 'Priya Sharma',
  );
  return Routes.settle(
    groupId: w.group,
    from: f.id,
    to: me.id,
    currency: 'INR',
  );
}

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

/// Opens the editor at [location] on [v] and the date picker from its
/// Date row; false when it did not open.
Future<bool> _openPicker(
  WidgetTester tester,
  VisualPhone phone,
  Variant v,
  String location,
) async {
  await pumpVisual(tester, phone, v: v, location: location);
  if (!await _semanticTap(tester, RegExp(r'^Date, '))) return false;
  return _dialog.evaluate().isNotEmpty;
}

/// Puts a keyboard of [height] dp over the bottom of the screen.
Future<void> _keyboard(WidgetTester tester, double height) async {
  tester.view.viewInsets = FakeViewPadding(
    bottom: height * tester.view.devicePixelRatio,
  );
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpAndSettle();
}

/// Whether [f]'s first match is painted: no fully transparent opacity
/// above it.
bool _painted(WidgetTester tester, Finder f) {
  if (f.evaluate().isEmpty) return false;
  RenderObject? r = tester.renderObject(f.first);
  while (r != null) {
    if (r is RenderOpacity && r.opacity == 0) return false;
    if (r is RenderAnimatedOpacity && r.opacity.value == 0) return false;
    r = r.parent;
  }
  return true;
}

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R10-01 / -02 reverification guards (pass).
  // ------------------------------------------------------------------

  testWidgets(
    'VISUAL-R10 class: with the keyboard up the input-only picker keeps its '
    'field and buttons above it, full size, with no overflow',
    (tester) async {
      await tester.runAsync(loadRealFonts);
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final openers = {
        'expense': Routes.editExpense(w.expense),
        'payment': Routes.editExpense(w.payment),
        'settle': _settle(w),
      };
      // A phone keyboard is 260 to 300 dp tall in portrait.
      for (final v in kVariants) {
        for (final e in openers.entries) {
          for (final kb in const [260.0, 300.0]) {
            final where = '${variantName(v)} ${e.key} kb $kb';
            var opened = false;
            final errors = await collectLayoutErrors(() async {
              opened = await _openPicker(tester, w.phone, v, e.value);
              if (opened) await _keyboard(tester, kb);
            });
            if (!opened) {
              problems.add('$where: the date picker did not open');
              continue;
            }
            problems.addAll(errors.map((x) => '$where: $x'));
            final field = _inDialog(find.byType(TextField));
            if (field.evaluate().isNotEmpty) {
              final top = v.size.height - kb;
              final f = tester.getRect(field.first);
              final ok = tester.getRect(
                _inDialog(
                  find.ancestor(
                    of: find.text('OK'),
                    matching: find.byType(TextButton),
                  ),
                ),
              );
              if (f.bottom > top + 0.5) {
                problems.add('$where: the field $f is under the keyboard');
              }
              if (ok.bottom > top + 0.5) {
                problems.add('$where: OK $ok is under the keyboard');
              }
              for (final g in [
                androidTapTargetGuideline,
                labeledTapTargetGuideline,
              ]) {
                final r = await g.evaluate(tester);
                if (!r.passed) {
                  problems.add(
                    '$where: ${(r.reason ?? '').split('\n').take(2).join(' ')}',
                  );
                }
              }
            }
            tester.view.resetViewInsets();
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'VISUAL-R10 class: with a 48 dp navigation bar the 360 dp calendar, its '
    'year list and input mode meet the tap target guidelines',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      for (final v in [
        _v(360, 1.0),
        _v(360, 1.3, Brightness.dark),
        _v(360, 2.0),
      ]) {
        final where = variantName(v);
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(
            tester,
            w.phone,
            v: v,
            location: Routes.editExpense(w.expense),
          );
          tester.view.padding = const FakeViewPadding(
            top: 24 * 3,
            bottom: 48 * 3,
          );
          await tester.pumpAndSettle();
          await _semanticTap(tester, RegExp(r'^Date, '));
        });
        problems.addAll(errors.map((x) => '$where: $x'));
        Future<void> check(String tag) async {
          for (final g in [
            androidTapTargetGuideline,
            labeledTapTargetGuideline,
          ]) {
            final r = await g.evaluate(tester);
            if (!r.passed) {
              problems.add(
                '$where $tag: '
                '${(r.reason ?? '').split('\n').take(2).join(' ')}',
              );
            }
          }
        }

        await check('open');
        if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
          problems.addAll(
            (await collectLayoutErrors(() async {
              await tester.tap(find.text('November 2026'));
              await tester.pumpAndSettle();
            })).map((x) => '$where years: $x'),
          );
          await check('years');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // New findings, round 11 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R11-01: the input-only date picker takes US month-first '
    'dates with no format shown, so a day-first date is saved as another '
    'date',
    skip: true, // QA VISUAL-R11-01
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      // The variants where the editors now open the picker in input mode
      // only, with the keyboard up (the field takes focus on open).
      for (final v in [
        _v(320, 1.0),
        _v(320, 2.0, Brightness.dark),
        _v(360, 2.0),
      ]) {
        final where = variantName(v);
        if (!await _openPicker(
          tester,
          w.phone,
          v,
          Routes.editExpense(w.expense),
        )) {
          problems.add('$where: the date picker did not open');
          continue;
        }
        if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
          problems.add('$where: opened in calendar mode (repro needs input)');
          await tester.pumpWidget(const SizedBox.shrink());
          continue;
        }
        await _keyboard(tester, 280);
        final field = _inDialog(find.byType(TextField));
        final text = tester.widget<TextField>(field).controller!.text;
        // The expense is dated Mon 9 Nov 2026; the app writes it "9 Nov".
        final dayFirst = text == '09/11/2026';
        final formatShown =
            _painted(
              tester,
              _inDialog(
                find.textContaining(RegExp('mm/dd', caseSensitive: false)),
              ),
            ) ||
            _painted(
              tester,
              _inDialog(
                find.textContaining(RegExp('month', caseSensitive: false)),
              ),
            );
        if (!dayFirst && !formatShown) {
          problems.add(
            '$where: 9 Nov shows as "$text" with no format on screen '
            '(header shown: ${_painted(tester, _inDialog(find.text('Select date')))})',
          );
        }
        // A user who reads dates as the app writes them changes the day to
        // the 5th: "05/11/2026".
        await tester.enterText(field, '05/11/2026');
        await tester.tap(_inDialog(find.text('OK')));
        await tester.pumpAndSettle();
        final row = _node(tester, RegExp(r'^Date, '));
        final label = row?.getSemanticsData().label ?? '';
        if (!dayFirst && !label.contains('5 Nov')) {
          problems.add(
            '$where: "05/11/2026" was saved as "$label", not 5 Nov, '
            'without a warning',
          );
        }
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R11-02: in the dark theme the date picker secondary text '
    '(year list, "Select date", "Enter Date") is 4.28:1 on its surface',
    skip: true, // QA VISUAL-R11-02
    (tester) async {
      await tester.runAsync(loadRealFonts);
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      Color surface() => tester
          .widget<Material>(_inDialog(find.byType(Material)).first)
          .color!;
      void textCheck(String where, String text) {
        final f = _inDialog(find.text(text));
        if (f.evaluate().isEmpty) return;
        final p = tester.renderObject<RenderParagraph>(
          find.descendant(of: f.first, matching: find.byType(RichText)).first,
        );
        final style = p.text.style!;
        final size = p.textScaler.scale(style.fontSize!);
        // WCAG large text: 18 pt (24 px) or 14 pt (18.66 px) bold.
        final bold = (style.fontWeight ?? FontWeight.w400).value >= 700;
        final large = size >= 24 || (bold && size >= 18.66);
        final ratio = _contrast(style.color!, surface());
        if (ratio < (large ? 3.0 : 4.5)) {
          problems.add(
            '$where: "$text" ${size.toStringAsFixed(1)} dp is '
            '${ratio.toStringAsFixed(2)}:1 on the picker surface',
          );
        }
      }

      for (final v in [
        _v(360, 1.0, Brightness.dark),
        _v(320, 1.0, Brightness.dark),
      ]) {
        final where = variantName(v);
        if (!await _openPicker(
          tester,
          w.phone,
          v,
          Routes.editExpense(w.expense),
        )) {
          problems.add('$where: the date picker did not open');
          continue;
        }
        await tester.pumpAndSettle();
        textCheck(where, 'Select date');
        if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
          await tester.tap(find.text('November 2026'));
          await tester.pumpAndSettle();
          final r = await textContrastGuideline.evaluate(tester);
          if (!r.passed) {
            final years = RegExp(r'label: "(\d{4})"')
                .allMatches(r.reason ?? '')
                .map((m) => m.group(1))
                .toList();
            final ratio = RegExp(r'found ([0-9.]+)').firstMatch(r.reason ?? '');
            problems.add(
              '$where years: ${years.length} years at ${ratio?.group(1)}:1, '
              'e.g. ${years.take(3).join(', ')}',
            );
          }
          await tester.tap(find.text('2026'));
          await tester.pumpAndSettle();
          await tester.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
          await tester.pumpAndSettle();
        }
        textCheck(where, 'Enter Date');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
