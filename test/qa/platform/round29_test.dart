// PLATFORM round 29 (final regression sweep): probes of the code merged
// since round 24 where it meets the platform. Every text field now runs
// WellFormedTextFormatter first, so what an Android IME sends (selection
// and composing region in UTF-16 offsets, possibly cutting a surrogate
// pair) must come back as a value the engine accepts: well-formed text, a
// selection inside it and a composing region that is empty or a proper
// range inside it. The engine echoes a value back, so a second pass must
// change nothing.
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/ui/format/well_formed_formatter.dart';

const _alphabet = <String>[
  'a',
  'b',
  ' ',
  '\u{1F600}',
  '\uD83D',
  '\uDE00',
  '‍',
  'क',
  '्',
];

void _checkValue(TextEditingValue v) {
  final len = v.text.length;
  expect(TextClean.isWellFormed(v.text), isTrue, reason: 'text $v');
  final s = v.selection;
  if (s.isValid) {
    expect(s.baseOffset, inInclusiveRange(0, len), reason: '$v');
    expect(s.extentOffset, inInclusiveRange(0, len), reason: '$v');
  }
  final c = v.composing;
  if (c.isValid) {
    expect(c.start, inInclusiveRange(0, len), reason: '$v');
    expect(c.end, inInclusiveRange(0, len), reason: '$v');
    expect(c.start <= c.end, isTrue, reason: 'reversed composing: $v');
  }
}

void main() {
  const f = WellFormedTextFormatter();

  test('IME edits with lone surrogates come back as values the engine '
      'accepts (selection and composing inside the cleaned text)', () {
    final rnd = Random(29);
    for (var i = 0; i < 20000; i++) {
      final n = rnd.nextInt(8);
      final text = List.generate(
        n,
        (_) => _alphabet[rnd.nextInt(_alphabet.length)],
      ).join();
      final len = text.length;
      int off() => rnd.nextInt(len + 1);
      final a = off(), b = off();
      final selection = rnd.nextInt(10) == 0
          ? const TextSelection.collapsed(offset: -1)
          : TextSelection(baseOffset: a, extentOffset: b);
      final x = off(), y = off();
      final composing = rnd.nextInt(3) == 0
          ? TextRange.empty
          : TextRange(start: min(x, y), end: max(x, y));
      final value = TextEditingValue(
        text: text,
        selection: selection,
        composing: composing,
      );
      final out = f.formatEditUpdate(TextEditingValue.empty, value);
      _checkValue(out);
      // Running it again changes nothing (the engine echoes the value back).
      expect(f.formatEditUpdate(out, out), out);
    }
  });

  test('a caret between the halves of a pair whose high half is lone moves '
      'onto the kept text', () {
    // 'a' + lone high + 'b': the caret after the lone half lands after 'a'.
    const value = TextEditingValue(
      text: 'a\uD83Db',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 1, end: 3),
    );
    final out = f.formatEditUpdate(TextEditingValue.empty, value);
    expect(out.text, 'ab');
    expect(out.selection, const TextSelection.collapsed(offset: 1));
    expect(out.composing, const TextRange(start: 1, end: 2));
  });
}
