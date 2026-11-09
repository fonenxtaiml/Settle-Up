// QA MONEY: CSV export of a group built through the real Ledger: column
// order, RFC 4180 escaping, CRLF, ASCII minus for numbers, formula-leading
// text cells, multi-currency rows, deleted rows excluded, merged/removed
// members, and every row's member columns summing to zero.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/money.dart';

import 'money_harness.dart';

/// Minimal RFC 4180 reader (quoted cells, doubled quotes, CRLF records).
List<List<String>> readCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"' && i + 1 < s.length && s[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (ch == '"') {
        quoted = false;
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add('$cell');
      cell.clear();
    } else if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') {
      row.add('$cell');
      cell.clear();
      rows.add(row);
      row = [];
      i++;
    } else {
      cell.write(ch);
    }
  }
  expect(
    cell.isEmpty && row.isEmpty && !quoted,
    isTrue,
    reason: 'every record ends with CRLF',
  );
  return rows;
}

int minorOf(String cell, int digits) {
  expect(
    cell,
    matches(RegExp(digits == 0 ? r'^-?\d+$' : '^-?\\d+\\.\\d{$digits}\$')),
    reason: 'plain ASCII decimal, "-" minus, no grouping: "$cell"',
  );
  return int.parse(cell.replaceAll('.', ''));
}

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me, sam, priya;

  setUp(() async {
    p = await QaPhone.create();
    final t = await p.group(['Sam', 'Priya']);
    g = t.g;
    me = t.m['me']!;
    sam = t.m['Sam']!;
    priya = t.m['Priya']!;
  });
  tearDown(() => p.dispose());

  test('columns, escaping, CRLF, multi-currency, deleted excluded', () async {
    await p.add(
      g,
      description: 'Dinner, "the good one"\nwith wine',
      total: 9000,
      paidBy: one(me, 9000),
      owedBy: eq([me, sam, priya]),
      dateMs: kBaseMs + 86400000,
    );
    await p.add(
      g,
      description: 'Sushi',
      currency: 'JPY',
      total: 1000,
      paidBy: one(sam, 1000),
      owedBy: eq([me, sam, priya]),
    );
    await p.add(
      g,
      description: 'Fuel',
      currency: 'KWD',
      total: 12345,
      paidBy: one(priya, 12345),
      owedBy: eq([me, priya]),
    );
    final gone = await p.add(
      g,
      description: 'Deleted one',
      total: 500,
      paidBy: one(me, 500),
      owedBy: eq([sam]),
    );
    await p.ledger.deleteExpense(gone);
    await p.pay(
      g,
      from: sam,
      to: me,
      amount: 3000,
      dateMs: kBaseMs + 2 * 86400000,
    );

    final csv = CsvExport.group(p.gs(g));
    expect(csv.replaceAll('\r\n', ''), isNot(contains('\r')));
    final rows = readCsv(csv);
    expect(rows.first.take(5), [
      'Date',
      'Description',
      'Category',
      'Cost',
      'Currency',
    ]);
    expect(rows.first.skip(5), [
      'Alex',
      'Priya',
      'Sam',
    ], reason: 'one column per active member, by name');
    expect(rows, hasLength(1 + 4), reason: 'deleted expense excluded');
    expect(csv, isNot(contains('Deleted one')));

    final dinner = rows.firstWhere((r) => r[1].startsWith('Dinner'));
    expect(dinner[1], 'Dinner, "the good one"\nwith wine');
    // The local calendar day of kBaseMs + 1 day (MONEY-R1-05).
    final l = DateTime.fromMillisecondsSinceEpoch(kBaseMs + 86400000);
    expect(
      dinner[0],
      '${l.year}-${l.month.toString().padLeft(2, '0')}-'
      '${l.day.toString().padLeft(2, '0')}',
    );
    expect(dinner.sublist(3), ['90.00', 'INR', '60.00', '-30.00', '-30.00']);

    final sushi = rows.firstWhere((r) => r[1] == 'Sushi');
    expect(sushi.sublist(3), ['1000', 'JPY', '-334', '-333', '667']);
    final fuel = rows.firstWhere((r) => r[1] == 'Fuel');
    expect(fuel.sublist(3), ['12.345', 'KWD', '-6.173', '6.173', '0.000']);
    final pay = rows.last;
    expect(pay[2], 'Payment');
    expect(pay[1], 'Sam paid Alex');

    // Every data row: member columns sum to 0 and the cost matches.
    for (final r in rows.skip(1)) {
      final digits = Currencies.of(r[4]).minorDigits;
      final cols = r.skip(5).map((c) => minorOf(c, digits));
      expect(cols.fold(0, (a, b) => a + b), 0, reason: 'row $r');
      expect(minorOf(r[3], digits), greaterThan(0));
    }
    // Rows sorted by date ascending.
    final dates = [for (final r in rows.skip(1)) r[0]];
    expect(dates, [...dates]..sort());
  });

  test('formula-leading text cells are neutralised (= + - @ tab CR)', () async {
    final risky = [
      '=HYPERLINK("x")',
      '+1+1',
      '-2+3',
      '@SUM(A1)',
      '\tTab',
      '\rCR',
    ];
    for (final d in risky) {
      await p.add(
        g,
        description: d,
        total: 100,
        paidBy: one(me, 100),
        owedBy: eq([sam]),
      );
    }
    await p.ledger.renameMember(g, priya, '=cmd|calc');
    final rows = readCsv(CsvExport.group(p.gs(g)));
    final descriptions = {for (final r in rows.skip(1)) r[1]};
    for (final d in risky) {
      // The ledger trims descriptions, so "\tTab" is stored as "Tab".
      final stored = d.trim();
      if (stored.isEmpty) continue;
      final first = stored[0];
      if ('=+-@\t\r'.contains(first)) {
        expect(descriptions, contains("'$stored"));
      } else {
        expect(descriptions, contains(stored));
      }
    }
    expect(rows.first, contains("'=cmd|calc"));
    // Numbers keep a bare '-' so spreadsheets still read them as numbers.
    expect(
      rows[1].skip(5).any((c) => c.startsWith('-') && !c.startsWith("'")),
      isTrue,
    );
  });

  test('a description starting with U+2212 is kept as text', () async {
    await p.add(
      g,
      description: '−20% refund',
      total: 100,
      paidBy: one(me, 100),
      owedBy: eq([sam]),
    );
    final rows = readCsv(CsvExport.group(p.gs(g)));
    expect(rows[1][1], '−20% refund');
    expect(
      rows[1].skip(5).join(),
      isNot(contains('−')),
      reason: 'numbers use ASCII minus',
    );
  });

  test(
    'merged member counted in the survivor column, removed member kept',
    () async {
      final sam2 = await p.ledger.addMember(g, displayName: 'Sam K');
      await p.add(
        g,
        total: 3000,
        paidBy: one(me, 3000),
        owedBy: eq([sam, sam2, priya]),
      );
      await p.ledger.mergeMembers(g, from: sam2, into: sam);
      await p.ledger.removeMember(g, priya);
      final rows = readCsv(CsvExport.group(p.gs(g)));
      expect(
        rows.first.skip(5),
        ['Alex', 'Sam', 'Priya'],
        reason:
            'removed member with a non-zero row comes after the active ones',
      );
      expect(rows[1].sublist(5), ['30.00', '-20.00', '-10.00']);
    },
  );

  test('Money.maxMinor rows', () async {
    await p.add(
      g,
      total: Money.maxMinor,
      paidBy: one(me, Money.maxMinor),
      owedBy: eq([me, sam, priya]),
    );
    final rows = readCsv(CsvExport.group(p.gs(g)));
    expect(rows[1].sublist(3), [
      '9999999.99',
      'INR',
      '6666666.66',
      '-3333333.33',
      '-3333333.33',
    ]);
  });

  // MONEY-R1-05. Meaningful in a non-UTC zone, e.g.
  //   TZ=America/Los_Angeles flutter test test/qa/money/csv_ledger_test.dart
  test(
    'CSV Date is the same calendar day the app shows for the expense',
    () async {
      // 9 Nov 2026 19:30 local in Los Angeles (03:30 UTC on 10 Nov), or
      // 02:00 local in Kolkata on 10 Nov (20:30 UTC on 9 Nov).
      for (final local in [
        DateTime(2026, 11, 9, 19, 30),
        DateTime(2026, 11, 10, 2, 0),
      ]) {
        await p.add(
          g,
          description: 'At ${local.hour}h',
          total: 100,
          paidBy: one(me, 100),
          owedBy: eq([sam]),
          dateMs: local.toUtc().millisecondsSinceEpoch,
        );
      }
      final rows = readCsv(CsvExport.group(p.gs(g)));
      for (final r in rows.skip(1)) {
        final e = p.gs(g).liveExpenses.firstWhere((x) => x.description == r[1]);
        final l = e.date.toLocal();
        final shown =
            '${l.year}-${l.month.toString().padLeft(2, '0')}-'
            '${l.day.toString().padLeft(2, '0')}';
        expect(r[0], shown, reason: 'TZ offset ${l.timeZoneOffset}');
      }
    },
  );
}
