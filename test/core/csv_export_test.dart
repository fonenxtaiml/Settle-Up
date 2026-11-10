import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/split.dart';

import 'helpers.dart';

/// Minimal RFC 4180 parser used to check the output round trips.
List<List<String>> parseCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var i = 0;
  var quoted = false;
  while (i < s.length) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        cell.write(ch);
      }
      i++;
      continue;
    }
    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
      i++;
    } else {
      cell.write(ch);
    }
    i++;
  }
  expect(cell.isEmpty && row.isEmpty, isTrue, reason: 'ends with CRLF');
  return rows;
}

void main() {
  // Noon on 9 and 10 Nov 2026 in the zone the tests run in: the Date
  // column is the local calendar day (MONEY-R1-05), so the expected dates
  // below hold in every zone.
  final day1 = DateTime(2026, 11, 9, 12).millisecondsSinceEpoch;
  final day2 = DateTime(2026, 11, 10, 12).millisecondsSinceEpoch;

  test('header, column order, sorting, amounts and payments', () {
    final g = groupOf([
      member('a', name: 'Alex'),
      member('b', name: 'Bob'),
      member('c', name: 'Cat'),
    ], [
      expense(equalBlock(1000, 'a', ['a', 'b', 'c']),
          id: 'e2', date: day2, description: 'Taxi', category: 'transport.taxi'),
      expense(equalBlock(500, 'b', ['a', 'b', 'c'], currency: 'JPY'),
          id: 'e1', date: day2, description: 'Ramen'),
      expense(SplitCalculator.paymentBlock(
              from: 'b', to: 'a', amount: 333, currency: 'GBP'),
          id: 'e0', date: day1, kind: ExpenseKind.payment, description: '',
          category: 'payment'),
      expense(equalBlock(100, 'a', ['a', 'b']),
          id: 'e9', date: day1, deleted: true, description: 'Gone'),
      expense(equalBlock(12345, 'c', ['c', 'a'], currency: 'KWD'),
          id: 'e3', date: day2 + 1, description: 'Fuel', category: 'nope'),
    ]);
    final csv = CsvExport.group(g);
    expect(csv.endsWith('\r\n'), isTrue);
    expect(csv.replaceAll('\r\n', '').contains('\n'), isFalse);
    expect(parseCsv(csv), [
      ['Date', 'Description', 'Category', 'Cost', 'Currency', 'Alex', 'Bob', 'Cat'],
      ['2026-11-09', 'Bob paid Alex', 'Payment', '3.33', 'GBP', '-3.33', '3.33', '0.00'],
      ['2026-11-10', 'Ramen', 'Dining out', '500', 'JPY', '-167', '333', '-166'],
      ['2026-11-10', 'Taxi', 'Taxi', '10.00', 'GBP', '6.66', '-3.33', '-3.33'],
      ['2026-11-10', 'Fuel', 'Uncategorized', '12.345', 'KWD', '-6.173', '0.000', '6.173'],
    ]);
  });

  test('escaping of commas, quotes and newlines', () {
    final g = groupOf([
      member('a', name: 'Smith, Jo'),
      member('b', name: 'Bo "B"'),
    ], [
      expense(equalBlock(200, 'a', ['a', 'b']),
          id: 'e1', date: day1, description: 'Dinner, drinks\nand "fun"'),
      expense(equalBlock(200, 'a', ['a', 'b']),
          id: 'e2', date: day1, description: 'Line\r\nbreak'),
    ]);
    final csv = CsvExport.group(g);
    expect(csv,
        startsWith('Date,Description,Category,Cost,Currency,"Bo ""B""","Smith, Jo"\r\n'));
    expect(csv, contains('"Dinner, drinks\nand ""fun"""'));
    final rows = parseCsv(csv);
    expect(rows[1][1], 'Dinner, drinks\nand "fun"');
    expect(rows[2][1], 'Line\r\nbreak');
    expect(rows.every((r) => r.length == 7), isTrue);
  });

  test('Date is the local calendar day, late evening and just after '
      'midnight included (MONEY-R1-05)', () {
    final late = DateTime(2026, 11, 9, 23, 30).millisecondsSinceEpoch;
    final early = DateTime(2026, 11, 10, 0, 30).millisecondsSinceEpoch;
    final g = groupOf([member('a', name: 'Alex'), member('b', name: 'Bob')], [
      expense(equalBlock(100, 'a', ['a', 'b']),
          id: 'e1', date: late, description: 'Late'),
      expense(equalBlock(100, 'a', ['a', 'b']),
          id: 'e2', date: early, description: 'Early'),
    ]);
    final rows = parseCsv(CsvExport.group(g));
    expect(rows[1].take(2), ['2026-11-09', 'Late']);
    expect(rows[2].take(2), ['2026-11-10', 'Early']);
  });

  test('formula-looking text is neutralised', () {
    final g = groupOf([member('a', name: '=cmd'), member('b')], [
      expense(equalBlock(100, 'a', ['a', 'b']),
          id: 'e1', date: day1, description: '=HYPERLINK("x")'),
    ]);
    final rows = parseCsv(CsvExport.group(g));
    expect(rows[0][5], "'=cmd");
    expect(rows[1][1], "'=HYPERLINK(\"x\")");
    expect(rows[1][6], '-0.50', reason: 'numbers are left alone');
  });

  test('merged members fold into their target, removed members kept', () {
    final g = groupOf([
      member('a', name: 'Alex'),
      member('b', name: 'Bob'),
      member('b2', name: 'Bob dup', mergedInto: 'b'),
      member('r', name: 'Rita', removed: true),
      member('z', name: 'Zed', removed: true),
    ], [
      expense(equalBlock(900, 'a', ['b', 'b2', 'r']), id: 'e1', date: day1),
    ]);
    final rows = parseCsv(CsvExport.group(g));
    expect(rows[0].sublist(5), ['Alex', 'Bob', 'Rita']);
    expect(rows[1].sublist(5), ['9.00', '-6.00', '-3.00']);
  });

  test('empty group has only the header', () {
    final g = groupOf([member('a', name: 'Alex')], []);
    expect(CsvExport.group(g),
        'Date,Description,Category,Cost,Currency,Alex\r\n');
  });

  test('member columns of every row sum to zero', () {
    final g = groupOf([
      member('a'),
      member('b'),
      member('c'),
    ], [
      for (var i = 0; i < 20; i++)
        expense(
            SplitCalculator.buildMoneyBlock(
              total: 1 + i * 137,
              currency: 'GBP',
              paidBy: SplitSpec.equal(['a', 'b']),
              owedBy: SplitSpec.equal(['a', 'b', 'c']),
            ),
            id: 'e$i',
            date: day1 + i),
    ]);
    final rows = parseCsv(CsvExport.group(g)).skip(1);
    for (final r in rows) {
      final cents = r.sublist(5).map((v) => int.parse(v.replaceAll('.', '')));
      expect(cents.fold(0, (a, b) => a + b), 0);
    }
  });
}
