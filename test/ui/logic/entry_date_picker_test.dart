// SECURITY-R5-01: the editors' date picker opens for every date the remote
// check accepts, and keeps its usual range for ordinary dates.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/screens/common.dart';

void main() {
  Future<DatePickerDialog> open(WidgetTester t, DateTime initial) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    pickEntryDate(ctx, initial: initial, now: DateTime(2026, 11, 10));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    return t.widget<DatePickerDialog>(find.byType(DatePickerDialog));
  }

  testWidgets('an ordinary date keeps the 2000 to next-year range', (t) async {
    final d = await open(t, DateTime(2026, 3, 4, 18, 30));
    expect(d.firstDate, DateTime(2000));
    expect(d.lastDate, DateTime(2027, 12, 31));
    expect(d.initialDate, DateTime(2026, 3, 4));
  });

  for (final date in [
    DateTime(1900, 1, 1),
    DateTime(1970, 1, 1, 5, 30),
    DateTime(1999, 12, 31, 23),
    DateTime(2028, 1, 1),
    DateTime(2090, 6, 1),
    DateTime(9999, 12, 31),
  ]) {
    testWidgets('a stored date of $date opens the picker on it', (t) async {
      final d = await open(t, date);
      final day = DateTime(date.year, date.month, date.day);
      expect(d.initialDate, day);
      expect(d.firstDate.isAfter(day), isFalse);
      expect(d.lastDate.isBefore(day), isFalse);
    });
  }
}
