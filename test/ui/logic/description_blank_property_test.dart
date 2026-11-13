// UIFLOW-R24-01: the expense editor's "is the description empty" test
// (isBlankDescription) is the Ledger's, over whole character classes, not
// only the reported characters. A seeded random mix of spaces, characters
// the Ledger drops, characters that render as blank, and visible letters,
// digits and symbols: the editor calls the description missing exactly
// when the Ledger refuses it as empty.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/screens/common.dart';

import '../../qa/money/money_harness.dart';

/// Spaces String.trim removes, plus line and paragraph breaks.
const _spaces = [
  0x09,
  0x0A,
  0x0B,
  0x0C,
  0x0D,
  0x20,
  0x85,
  0xA0,
  0x1680,
  0x2000,
  0x2005,
  0x200A,
  0x2028,
  0x2029,
  0x202F,
  0x205F,
  0x3000,
  0xFEFF,
];

/// Characters the Ledger drops: controls, bidi marks and controls,
/// zero-width space, word joiner, interlinear annotations, lone halves.
const _hidden = [
  0x00,
  0x07,
  0x1B,
  0x7F,
  0x80,
  0x9F,
  0x061C,
  0x200B,
  0x200E,
  0x200F,
  0x202A,
  0x202E,
  0x2060,
  0x2066,
  0x2069,
  0xFFF9,
  0xFFFB,
  0xD800,
  0xDBFF,
  0xDC00,
  0xDFFF,
];

/// Characters that render as blank on their own.
const _blank = [
  0x00AD,
  0x034F,
  0x115F,
  0x1160,
  0x17B4,
  0x180B,
  0x180E,
  0x200C,
  0x200D,
  0x2061,
  0x2064,
  0x206F,
  0x2800,
  0x3164,
  0xFE00,
  0xFE0F,
  0xFFA0,
  0xFFF0,
  0xFDD0,
  0xFFFE,
  0x1BCA0,
  0x1D173,
  0xE0001,
  0xE0020,
  0xE0100,
];

/// Characters that show: letters and digits of several scripts, symbols,
/// punctuation, an emoji.
const _visible = [
  0x41,
  0x7A,
  0x30,
  0x2E,
  0x2D,
  0x20B9,
  0xE9,
  0x0905,
  0x0967,
  0x4E2D,
  0xAC00,
  0x05D0,
  0x0627,
  0x1F600,
  0x2764,
  0x00B7,
];

void main() {
  test('isBlankDescription agrees with the Ledger on 400 seeded random '
      'descriptions mixing every character class', () async {
    final p = await QaPhone.create();
    addTearDown(p.dispose);
    final t = await p.group(['Sam']);
    final me = t.m['me']!;
    final r = Random(2024);
    var blanks = 0, kept = 0;
    for (var i = 0; i < 400; i++) {
      final classes = [
        _spaces,
        _hidden,
        _blank,
        // A visible character in about one string out of three.
        if (r.nextInt(3) == 0) _visible,
      ];
      final n = 1 + r.nextInt(6);
      final text = String.fromCharCodes([
        for (var k = 0; k < n; k++)
          () {
            final c = classes[r.nextInt(classes.length)];
            return c[r.nextInt(c.length)];
          }(),
      ]);
      bool refused;
      try {
        await p.ledger.addExpense(
          ExpenseDraft(
            groupId: t.g,
            description: text,
            total: 100,
            currency: 'INR',
            paidBy: SplitSpec(SplitMethod.exact, {me: 100}),
            owedBy: SplitSpec(SplitMethod.exact, {me: 100}),
            category: 'general',
            date: DateTime.utc(2026, 11, 12),
          ),
        );
        refused = false;
      } on LedgerException catch (e) {
        expect(e.code, LedgerErrorCode.invalidInput, reason: '$e');
        refused = true;
      }
      final codes = text.codeUnits.map((c) => c.toRadixString(16)).join(' ');
      expect(isBlankDescription(text), refused, reason: codes);
      // The editor trims before it checks; the answer is the same.
      expect(isBlankDescription(text.trim()), refused, reason: codes);
      refused ? blanks++ : kept++;
    }
    // Both outcomes are exercised.
    expect(blanks, greaterThan(100));
    expect(kept, greaterThan(50));
  });
}
