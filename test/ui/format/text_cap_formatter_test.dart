// TextCapFormatter, the one cap of every notes field (UIFLOW-R15-02):
// what is typed or pasted stays within the cap, text the field already
// holds is never cut, and typing a text gives the same field as pasting
// it. Seeded random edits over many character classes.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/text_cap_formatter.dart';

int _len(String s) => s.characters.length;

/// Pieces random texts are made of: ASCII, Latin with combining marks,
/// Devanagari with a virama and ZWJ, CJK, Hangul jamo, emoji with skin
/// tones and ZWJ sequences, flags (regional indicators), line breaks and
/// spaces of every kind.
const _pieces = [
  'a',
  'Z',
  '7',
  ' ',
  '.',
  ',',
  '\n',
  'é',
  '́',
  'ñ',
  'क',
  '्',
  'ष',
  '‍',
  'ि',
  '中',
  '文',
  'ᄀ',
  'ᅡ',
  'ᆨ',
  '👍',
  '🏽',
  '👩',
  '❤️',
  '\u{1F468}‍\u{1F469}‍\u{1F467}',
  '🇮',
  '🇳',
  '🇺',
  '🇸',
  ' ',
  ' ',
  '　',
];

String _random(Random r, int pieces, {bool startAscii = false}) {
  final b = StringBuffer(startAscii ? 'x' : '');
  for (var i = 0; i < pieces; i++) {
    b.write(_pieces[r.nextInt(_pieces.length)]);
  }
  return b.toString();
}

TextEditingValue _at(String text, int cursor) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor),
);

/// Grapheme boundaries of [s] (as code-unit offsets) followed by an ASCII
/// character or the end, where an insert cannot join the text after it.
List<int> _plainBoundaries(String s) {
  final out = <int>[];
  var off = 0;
  for (final g in s.characters) {
    if (RegExp(r'^[a-zA-Z0-9 .,]$').hasMatch(g)) out.add(off);
    off += g.length;
  }
  out.add(s.length);
  return out;
}

/// Types [text] at [cursor] one code point at a time.
TextEditingValue _type(
  TextCapFormatter f,
  TextEditingValue value,
  String text,
) {
  var v = value;
  for (final r in text.runes) {
    final c = String.fromCharCode(r);
    final at = v.selection.baseOffset;
    final next = _at(v.text.replaceRange(at, at, c), at + c.length);
    final out = f.formatEditUpdate(v, next);
    // A refused key leaves the cursor where it was.
    v = identical(out, v) ? v : out;
  }
  return v;
}

TextEditingValue _paste(
  TextCapFormatter f,
  TextEditingValue value,
  String text,
) {
  final at = value.selection.baseOffset;
  return f.formatEditUpdate(
    value,
    _at(value.text.replaceRange(at, at, text), at + text.length),
  );
}

void main() {
  test('an edit within the cap passes as it is', () {
    final f = TextCapFormatter(10);
    final next = _at('Dinner ok', 9);
    expect(f.formatEditUpdate(_at('Dinner', 6), next), same(next));
  });

  test('a note longer than the cap the field already holds is not cut by '
      'a key; the key is refused', () {
    final f = TextCapFormatter(10);
    final held = _at('x' * 15, 15);
    expect(f.formatEditUpdate(held, _at('${'x' * 15}y', 16)), same(held));
    expect(f.formatEditUpdate(held, _at('y${'x' * 15}', 1)), same(held));
  });

  test('a held over-long note can always be shortened', () {
    final f = TextCapFormatter(10);
    final held = _at('x' * 15, 15);
    final next = _at('x' * 14, 14);
    expect(f.formatEditUpdate(held, next), same(next));
    final cut = _at('x' * 3, 3);
    expect(
      f.formatEditUpdate(
        held.copyWith(
          selection: const TextSelection(baseOffset: 3, extentOffset: 15),
        ),
        cut,
      ),
      same(cut),
    );
  });

  test('a paste in the middle that runs over keeps the text after it and '
      'as much of the paste as fits', () {
    final f = TextCapFormatter(10);
    final out = f.formatEditUpdate(_at('abcdef', 3), _at('abcXYZWVUdef', 9));
    expect(out.text, 'abcXYZWdef');
    expect(out.selection.baseOffset, 7);
  });

  test('a combining mark or skin tone typed on the last character still '
      'goes in when the field is full', () {
    final f = TextCapFormatter(3);
    expect(f.formatEditUpdate(_at('abe', 3), _at('abé', 4)).text, 'abé');
    expect(f.formatEditUpdate(_at('ab👍', 4), _at('ab👍🏽', 6)).text, 'ab👍🏽');
    expect(f.formatEditUpdate(_at('ab🇮', 4), _at('ab🇮🇳', 6)).text, 'ab🇮🇳');
  });

  test('the edit that ends a composition over the cap is held to it', () {
    final f = TextCapFormatter(5);
    const composing = TextEditingValue(
      text: 'abcdefgh',
      selection: TextSelection.collapsed(offset: 8),
      composing: TextRange(start: 3, end: 8),
    );
    final out = f.formatEditUpdate(composing, _at('abcdefgh', 8));
    expect(out.text, 'abcde');
  });

  group('property (seeded)', () {
    for (final seed in List.generate(8, (i) => 1000 + i)) {
      test('seed $seed: never over the cap from within it, never cuts held '
          'text, keeps the text around the edit, typing == pasting', () {
        final r = Random(seed);
        for (var i = 0; i < 300; i++) {
          final limit = 1 + r.nextInt(30);
          final f = TextCapFormatter(limit);
          final base = _random(r, r.nextInt(40), startAscii: true);
          final held = _len(base) > limit;
          final points = _plainBoundaries(base);
          final at = points[r.nextInt(points.length)];
          final insert = _random(r, 1 + r.nextInt(30));
          final start = _at(base, at);
          final pasted = _paste(f, start, insert);
          final typed = _type(f, start, insert);
          final reason = 'limit $limit, base "$base" at $at, insert "$insert"';
          expect(typed.text, pasted.text, reason: reason);
          if (held) {
            // Over the cap already: only characters that join one before
            // them may go in, and nothing of the held text is lost.
            expect(
              _len(pasted.text),
              lessThanOrEqualTo(_len(base)),
              reason: reason,
            );
          } else {
            expect(_len(pasted.text), lessThanOrEqualTo(limit), reason: reason);
          }
          final head = base.substring(0, at);
          final tail = base.substring(at);
          expect(pasted.text.startsWith(head), isTrue, reason: reason);
          expect(pasted.text.endsWith(tail), isTrue, reason: reason);
          final kept = pasted.text.substring(
            head.length,
            pasted.text.length - tail.length,
          );
          // What went in is the insert with some code points left out,
          // never anything else.
          var j = 0;
          for (final c in kept.runes) {
            while (j < insert.runes.length && insert.runes.elementAt(j) != c) {
              j++;
            }
            expect(j, lessThan(insert.runes.length), reason: reason);
            j++;
          }
          // Room left means the whole insert went in.
          if (_len(head + insert + tail) <= limit) {
            expect(pasted.text, head + insert + tail, reason: reason);
          }
        }
      });
    }
  });
}
