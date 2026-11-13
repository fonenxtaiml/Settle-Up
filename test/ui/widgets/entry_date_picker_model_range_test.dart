// VISUAL-R12-01 regression: the date picker opens on every local date a
// model date can be (31 Dec 1899 west of UTC to 1 Jan 10000 east of it),
// and OK on the unchanged field keeps that date, in input mode (the only
// mode on a 320 dp phone) and after switching to it from the calendar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/screens/common.dart';

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Future<Future<DateTime?>> _open(
  WidgetTester t,
  Size size,
  DateTime initial,
) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox.shrink());
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: const [AppMaterialLocalizations.delegate],
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final r = pickEntryDate(ctx, initial: initial, now: DateTime(2026, 11, 10));
  await t.pumpAndSettle();
  if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
    await t.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
    await t.pumpAndSettle();
  }
  return r;
}

void main() {
  for (final size in const [Size(320, 568), Size(411, 891)]) {
    testWidgets('OK on the unchanged field keeps every edge of the model '
        'range (${size.width.toInt()} dp)', (t) async {
      final problems = <String>[];
      for (final d in [
        DateTime(1899, 12, 31),
        DateTime(1900, 1, 1),
        DateTime(9999, 12, 31),
        DateTime(10000, 1, 1),
      ]) {
        final pending = await _open(t, size, d);
        final shown = t
            .widget<TextField>(_inDialog(find.byType(TextField)))
            .controller
            ?.text;
        await t.tap(_inDialog(find.text('OK')));
        await t.pumpAndSettle();
        if (_dialog.evaluate().isNotEmpty) {
          problems.add('$d: field "$shown", OK refused');
          await t.pumpWidget(const SizedBox.shrink());
          continue;
        }
        final got = await pending;
        if (got != d) problems.add('$d: field "$shown", saved as $got');
        await t.pumpWidget(const SizedBox.shrink());
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('a five-digit year past the range is out of range, not an '
      'invalid format', (t) async {
    final pending = await _open(t, const Size(320, 568), DateTime(10000, 1, 1));
    await t.enterText(_inDialog(find.byType(TextField)), '02/01/10000');
    await t.tap(_inDialog(find.text('OK')));
    await t.pumpAndSettle();
    expect(_dialog, findsOneWidget);
    expect(_inDialog(find.text('Out of range.')), findsOneWidget);
    expect(_inDialog(find.text('Invalid format.')), findsNothing);
    await t.tap(_inDialog(find.text('Cancel')));
    await t.pumpAndSettle();
    expect(await pending, isNull);
  });
}
