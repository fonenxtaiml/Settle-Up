// MONEY-R1-09 / UIFLOW-R1-09: CSV file names and the UTF-8 BOM.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/screens/csv_share.dart';

import '../../qa/money/money_harness.dart';

void main() {
  test('file names keep every script and fall back when empty', () {
    expect(csvFileName('Goa trip'), 'Goa trip.csv');
    expect(csvFileName('गोवा ट्रिप'), 'गोवा ट्रिप.csv');
    expect(csvFileName('Zoë & Kai / 2026'), 'Zoë Kai 2026.csv');
    expect(csvFileName('🏖️'), '$kCsvFallbackName.csv');
    expect(csvFileName('  ...  '), '$kCsvFallbackName.csv');
    expect(csvFileName('a:b*c?"d<e>f|g\\h'), 'abcdefgh.csv');
  });

  test('a long name is cut on a character boundary (DATA-R3-02)', () {
    // 2 UTF-16 units per letter: 50 of them pass the 80-unit cut.
    final name = 'a${'\u{20000}' * 50}${'b' * 9}';
    final file = csvFileName(name);
    expect(file, 'a${'\u{20000}' * 39}.csv');
    expect(utf8.decode(utf8.encode(file)), file);
    // A letter with its combining mark stays whole too.
    final marks = '${'x' * 79}e\u0301';
    expect(csvFileName(marks), '${'x' * 79}.csv');
    // Names that fit are kept as they are.
    expect(csvFileName('b' * 80), '${'b' * 80}.csv');
  });

  test('the CSV starts with a UTF-8 BOM and keeps non-Latin text', () async {
    final p = await QaPhone.create(home: 'INR');
    final t = await p.group(['Zoë']);
    await p.add(
      t.g,
      description: 'गोवा dinner',
      total: 60000,
      paidBy: one(t.m['me']!, 60000),
      owedBy: eq([t.m['me']!, t.m['Zoë']!]),
    );
    final bytes = csvBytes(p.gs(t.g));
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    final text = utf8.decode(bytes.skip(3).toList());
    expect(text, contains('गोवा dinner'));
    expect(text, contains('Zoë'));
    await p.dispose();
  });
}
