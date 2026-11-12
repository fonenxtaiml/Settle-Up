// UIFLOW-R24-01: every text field drops lone UTF-16 surrogates first, so
// it never holds text the engine cannot draw and the checks after it see
// what the Ledger will save.
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/ui/format/well_formed_formatter.dart';

TextEditingValue _fmt(String text, int caret) =>
    const WellFormedTextFormatter().formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );

void main() {
  test('a well-formed text passes as it is, emoji included', () {
    for (final t in ['', 'Dinner', '😀 tip', 'नमस्ते', '🇮🇳 trip']) {
      final v = _fmt(t, t.length);
      expect(v.text, t);
      expect(v.selection.baseOffset, t.length);
    }
  });

  test('lone halves are dropped and the caret keeps its place', () {
    final v = _fmt('a\uD83Db\uDE00c', 4);
    expect(v.text, 'abc');
    expect(v.selection.baseOffset, 2);
    expect(_fmt('\uD83D', 1).text, '');
    expect(_fmt('😀\uD83D', 3).text, '😀');
    expect(_fmt('😀\uD83D', 3).selection.baseOffset, 2);
  });

  test('seeded random code units always come out well formed, keeping '
      'every pair and every other unit', () {
    final r = Random(24);
    const units = [0x41, 0x20, 0xD83D, 0xDE00, 0xD800, 0xDFFF, 0x200B, 0xE9];
    for (var i = 0; i < 2000; i++) {
      final s = String.fromCharCodes([
        for (var k = 0; k < r.nextInt(10); k++) units[r.nextInt(units.length)],
      ]);
      final caret = r.nextInt(s.length + 1);
      final v = _fmt(s, caret);
      expect(TextClean.isWellFormed(v.text), isTrue);
      expect(v.text, TextClean.wellFormed(s));
      expect(v.selection.baseOffset, inInclusiveRange(0, v.text.length));
    }
  });
}
