// VISUAL-R11-01 regression: dates in Material widgets are written and read
// day first, like the rest of the app, over the whole class of typed text,
// not only the reported "05/11/2026".
//
// * Every day from 1900 to 2100 is written dd/mm/yyyy and reads back as
//   itself, with any one of the accepted separators and with or without
//   leading zeros.
// * Day first: whenever the day and the month could swap, the text is read
//   with the day first.
// * Seeded random strings over digits, separators, letters, spaces and
//   look-alike characters: a string reads as a date if and only if it is
//   day/month/four-digit-year with one separator and a real calendar day,
//   checked against an independent oracle.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';

const l = AppMaterialLocalizations();

/// The oracle: what a typed date means, worked out without a pattern.
DateTime? oracle(String text) {
  final s = text.trim();
  String? sep;
  for (final c in const ['/', '-', '.']) {
    if (s.contains(c)) {
      if (sep != null) return null;
      sep = c;
    }
  }
  if (sep == null) return null;
  final parts = s.split(sep);
  if (parts.length != 3) return null;
  bool digits(String p) => p.codeUnits.every((u) => u >= 0x30 && u <= 0x39);
  if (!parts.every(digits)) return null;
  final [d, m, y] = parts;
  if (d.isEmpty || d.length > 2 || m.isEmpty || m.length > 2) return null;
  if (y.length != 4) return null;
  final day = int.parse(d), month = int.parse(m), year = int.parse(y);
  if (year < 1 || month < 1 || month > 12 || day < 1) return null;
  if (day > DateUtils.getDaysInMonth(year, month)) return null;
  return DateTime(year, month, day);
}

void main() {
  test('the field shows and names the day-first format', () {
    expect(l.dateHelpText, 'dd/mm/yyyy');
    expect(l.dateInputLabel, contains('dd/mm/yyyy'));
    final d = DateTime(2026, 11, 9);
    expect(l.formatCompactDate(d), '09/11/2026');
    expect(l.formatMediumDate(d), 'Mon, 9 Nov');
    expect(l.formatFullDate(d), 'Monday, 9 November 2026');
    expect(l.formatShortDate(d), '9 Nov 2026');
    expect(l.formatShortMonthDay(d), '9 Nov');
    // The month and year row is unchanged.
    expect(l.formatMonthYear(d), 'November 2026');
  });

  test('the reported date reads as the 5th of November', () {
    expect(l.parseCompactDate('05/11/2026'), DateTime(2026, 11, 5));
    expect(l.parseCompactDate('5/11/2026'), DateTime(2026, 11, 5));
    expect(l.parseCompactDate('11/05/2026'), DateTime(2026, 5, 11));
  });

  test('every day from 1900 to 2100 round-trips, day first', () {
    final bad = <String>[];
    for (
      var d = DateTime(1900, 1, 1);
      d.year <= 2100;
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final text = l.formatCompactDate(d);
      if (l.parseCompactDate(text) != d) bad.add(text);
      for (final sep in const ['/', '-', '.']) {
        final loose = '${d.day}$sep${d.month}$sep${d.year}';
        if (l.parseCompactDate(loose) != d) bad.add(loose);
      }
      if (bad.length > 20) break;
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('impossible and partial dates read as nothing', () {
    for (final s in const [
      '',
      ' ',
      '31/02/2026',
      '29/02/2025',
      '00/11/2026',
      '05/00/2026',
      '05/13/2026',
      '32/01/2026',
      '05/11/26',
      '05/11/20266',
      '05/11/0000',
      '05/11',
      '05//2026',
      '005/11/2026',
      '05/011/2026',
      '05/11-2026',
      '05 / 11 / 2026',
      '05/11/ 2026',
      '05/11/2026/',
      '/05/11/2026',
      '+5/11/2026',
      '-5/11/2026',
      '05/11/2026 ',
      '٠٥/١١/٢٠٢٦', // Arabic-Indic digits
      '०५/११/२०२६', // Devanagari digits
      '０５/１１/２０２６', // full-width digits
      '05​/11/2026',
      '05／11／2026', // full-width solidus
      '2026-11-05',
      '5 Nov 2026',
      'Nov 5, 2026',
    ]) {
      final got = l.parseCompactDate(s);
      expect(got, oracle(s), reason: '"$s" read as $got');
    }
    // A trailing space is trimmed, like the stock field.
    expect(l.parseCompactDate('05/11/2026 '), DateTime(2026, 11, 5));
    expect(l.parseCompactDate(null), isNull);
  });

  test('seeded random text reads as a date exactly when it is one', () {
    const alphabet = [
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', //
      '0', '1', '2', '9', '/', '/', '/', '-', '.', ' ', '\t', //
      ' ', '​', '−', '⁄', '／', '٣', '३', '５', //
      'a', 'O', 'l', ',', ':', '+', '(', ')', '\n',
    ];
    final r = math.Random(20261111);
    var dates = 0;
    final bad = <String>[];
    for (var n = 0; n < 200000 && bad.length < 20; n++) {
      final String s;
      if (n.isEven) {
        // Near-dates: a real shape with one character changed, added or
        // dropped.
        final d = 1 + r.nextInt(31), m = 1 + r.nextInt(13);
        final y = 1990 + r.nextInt(60);
        final sep = const ['/', '-', '.'][r.nextInt(3)];
        var t = '$d$sep$m$sep$y';
        if (r.nextBool()) {
          t =
              '${d.toString().padLeft(2, '0')}$sep'
              '${m.toString().padLeft(2, '0')}$sep$y';
        }
        final i = r.nextInt(t.length + 1);
        final c = alphabet[r.nextInt(alphabet.length)];
        s = switch (r.nextInt(4)) {
          0 => t,
          1 => t.substring(0, i) + c + t.substring(i),
          2 when i < t.length => t.substring(0, i) + c + t.substring(i + 1),
          _ when i < t.length => t.substring(0, i) + t.substring(i + 1),
          _ => t,
        };
      } else {
        final len = r.nextInt(14);
        s = List.generate(
          len,
          (_) => alphabet[r.nextInt(alphabet.length)],
        ).join();
      }
      final got = l.parseCompactDate(s);
      final want = oracle(s);
      if (got != want) bad.add('"$s": got $got, want $want');
      if (got != null) {
        dates++;
        // A date read back is shown as itself.
        final shown = l.formatCompactDate(got);
        if (l.parseCompactDate(shown) != got) bad.add('"$s" -> "$shown"');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
    // The sample really did contain dates.
    expect(dates, greaterThan(10000));
  });

  testWidgets('the app delegate puts the day-first strings in every widget', (
    t,
  ) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppMaterialLocalizations.delegate],
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(MaterialLocalizations.of(ctx), isA<AppMaterialLocalizations>());
  });
}
