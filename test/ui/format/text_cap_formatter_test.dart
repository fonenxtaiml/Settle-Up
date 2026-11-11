// TextCapFormatter, the one cap of every notes field (UIFLOW-R15-02):
// what is typed or pasted stays within the cap, text the field already
// holds is never cut, and typing a text gives the same field as pasting
// it. Seeded random edits over many character classes.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/format/text_cap_formatter.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

/// The length the cap holds: the text as the Ledger stores it, in
/// characters (UIFLOW-R18-01).
int _len(String s) => TextCapFormatter.length(s);

/// Pieces random texts are made of: ASCII, Latin with combining marks,
/// Devanagari with a virama and ZWJ, CJK, Hangul jamo, emoji with skin
/// tones and ZWJ sequences, flags (regional indicators), line breaks and
/// spaces of every kind, and the hidden characters the Ledger drops.
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
  // A family of four (11 code units) and a letter under four stacked
  // combining marks (5 code units): one character each, heavier than the
  // Ledger's 4 code units a character.
  '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}',
  'e\u0301\u0302\u0303\u0304',
  '🇮',
  '🇳',
  '🇺',
  '🇸',
  ' ',
  ' ',
  '　',
  // Characters the Ledger drops or turns into a line break (TextClean):
  // zero-width space, word joiner, BOM, bidi marks, embeddings,
  // overrides and isolates, a C0 and a C1 control, and every break.
  '\u200B',
  '\u2060',
  '\uFEFF',
  '\u200E',
  '\u200F',
  '\u061C',
  '\u202A',
  '\u202E',
  '\u2066',
  '\u2069',
  '\u0007',
  '\u0090',
  '\r',
  '\r\n',
  '\t',
  '\u000B',
  '\u0085',
  '\u2028',
  '\u2029',
  // Kept by the Ledger although they draw nothing.
  '\u00AD',
  '\u3164',
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

  // UIFLOW-R17-02: every free-text counter and "too long" message measures
  // as the Ledger does.
  group('TextCap is the Ledger\'s measure (seeded)', () {
    for (final seed in List.generate(4, (i) => 1700 + i)) {
      test('seed $seed: fits == TextRules.tooLong is null, length agrees, and '
          'notesInputError / descriptionInputError say what the Ledger '
          'says', () {
        final r = Random(seed);
        for (var i = 0; i < 2000; i++) {
          final limit = 1 + r.nextInt(40);
          final t = _random(r, r.nextInt(80));
          final ledger = TextRules.tooLong(t, limit) == null;
          expect(TextCap.fits(t, limit), ledger, reason: 'limit $limit "$t"');
          expect(TextCap.length(t) <= limit, ledger, reason: '"$t"');
        }
        for (var i = 0; i < 200; i++) {
          final big = _random(r, 200 + r.nextInt(1200));
          final cleaned = TextRules.clean(big, multiline: true);
          expect(
            notesInputError(big) == null,
            TextRules.tooLong(cleaned, TextRules.notes) == null,
          );
          expect(
            descriptionInputError(big) == null,
            TextRules.tooLong(cleaned, TextRules.description) == null,
          );
          if (notesInputError(big) != null) {
            expect(notesInputError(big), S.errTooLong);
          }
        }
      });
    }
  });

  test('400 family emoji: 400 characters but over the Ledger\'s code units '
      'for 1000; counted as 1100', () {
    final t = List.filled(
      400,
      '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}',
    ).join();
    expect(t.characters.length, 400);
    expect(TextCap.length(t), 1100);
    expect(TextCap.fits(t, 1000), isFalse);
    expect(notesInputError(t), S.errTooLong);
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

  // UIFLOW-R18-01: the cap measures the text as the Ledger stores it
  // (TextClean.clean, then characters), the measure the counters show, so
  // a character the Ledger drops takes no room.
  group('UIFLOW-R18-01: hidden characters take no room', () {
    test('600 letters each followed by a zero-width space are kept whole, '
        'and a letter typed after them goes in', () {
      final f = TextCapFormatter(1000);
      final pasted = List.filled(600, 'a\u200B').join();
      final out = _paste(f, _at('', 0), pasted);
      expect(out.text, pasted);
      expect(_len(out.text), 600);
      final typed = _type(f, out, 'b');
      expect(typed.text, '${pasted}b');
    });

    for (final hidden in [
      '\u200B',
      '\u2060',
      '\uFEFF',
      '\u200E',
      '\u200F',
      '\u061C',
      '\u202A',
      '\u202B',
      '\u202C',
      '\u202D',
      '\u202E',
      '\u2066',
      '\u2067',
      '\u2068',
      '\u2069',
      '\u0000',
      '\u001F',
      '\u007F',
      '\u0090',
      '\u009F',
      '\uFFF9',
      '\uFFFB',
    ]) {
      final code = hidden.runes.first.toRadixString(16).toUpperCase();
      test('U+$code: a full field still takes it, and it never takes the '
          'room of a letter', () {
        final f = TextCapFormatter(10);
        final full = _at('a' * 10, 10);
        expect(_type(f, full, hidden * 5).text, 'a' * 10 + hidden * 5);
        final mixed = List.filled(10, 'b$hidden').join();
        expect(_paste(f, _at('', 0), mixed).text, mixed);
        expect(_paste(f, _at('', 0), '$mixed${'c' * 3}').text, mixed);
      });
    }

    test(r'in notes \r\n is one line break, a lone \r another', () {
      final f = TextCapFormatter(5);
      expect(_paste(f, _at('', 0), 'ab\r\ncd').text, 'ab\r\ncd');
      expect(_paste(f, _at('', 0), 'ab\r\ncde').text, 'ab\r\ncd');
      expect(_paste(f, _at('', 0), 'ab\r\u200B\ncd').text, 'ab\r\u200B\nc');
      // A \n typed after a \r joins it into one line break.
      expect(_type(f, _at('abc\r', 4), '\nd').text, 'abc\r\nd');
    });

    test('spaces at either end take no room until text follows them', () {
      final f = TextCapFormatter(3);
      expect(_type(f, _at('abc', 3), '   x').text, 'abc   ');
      expect(_paste(f, _at('abc', 3), '   x').text, 'abc   ');
      expect(_paste(f, _at('abc', 0), '  ').text, '  abc');
      // "c" would make it "ab c"; the space after it is trailing again.
      expect(_paste(f, _at('ab', 2), ' \u200Bc d').text, 'ab \u200B ');
    });

    test('the formatter and every counter measure alike: the counter is '
        'TextCap.length of the cleaned text', () {
      final t = List.filled(600, 'a\u200B\u202E').join();
      expect(_len(t), TextCap.length(TextRules.clean(t, multiline: true)));
      expect(notesInputError(t), isNull);
    });
  });

  /// What the formatter is meant to do, the slow way: an edit within the
  /// cap passes, a deletion passes, and otherwise each inserted code point
  /// is kept when the text after it, measured whole, fits or is no longer
  /// than before it.
  String reference(
    int limit,
    String head,
    String inserted,
    String tail, {
    bool multiline = true,
  }) {
    int m(String s) => TextCapFormatter.length(s, multiline: multiline);
    if (m(head + inserted + tail) <= limit) return head + inserted + tail;
    final kept = StringBuffer();
    var count = m(head + tail);
    for (final r in inserted.runes) {
      final c = String.fromCharCode(r);
      final n = m('$head$kept$c$tail');
      if (n <= max(limit, count)) {
        kept.write(c);
        count = n;
      }
    }
    return '$head$kept$tail';
  }

  /// A code-point offset of [s] at random (never inside a surrogate pair).
  int anyOffset(Random r, String s) {
    final offsets = <int>[0];
    var o = 0;
    for (final c in s.runes) {
      o += c > 0xFFFF ? 2 : 1;
      offsets.add(o);
    }
    return offsets[r.nextInt(offsets.length)];
  }

  group('UIFLOW-R18-01 property (seeded): the cap is the Ledger\'s measure '
      'at any place of any text', () {
    for (final seed in List.generate(8, (i) => 1800 + i)) {
      for (final multiline in [true, false]) {
        test('seed $seed, multiline $multiline: equal to measuring the whole '
            'text for each code point, typing == pasting, and never over '
            'the cap as stored', () {
          final r = Random(seed);
          for (var i = 0; i < 300; i++) {
            final limit = 1 + r.nextInt(30);
            final f = TextCapFormatter(limit, multiline: multiline);
            int m(String s) => TextCapFormatter.length(s, multiline: multiline);
            final base = _random(r, r.nextInt(40));
            final at = anyOffset(r, base);
            final insert = _random(r, 1 + r.nextInt(30));
            final head = base.substring(0, at);
            final tail = base.substring(at);
            final reason =
                'limit $limit, base ${base.runes.toList()} at $at, '
                'insert ${insert.runes.toList()}';
            final start = _at(base, at);
            final pasted = _paste(f, start, insert);
            expect(
              pasted.text,
              reference(limit, head, insert, tail, multiline: multiline),
              reason: reason,
            );
            expect(
              m(pasted.text),
              lessThanOrEqualTo(max(limit, m(base))),
              reason: reason,
            );
            expect(pasted.text.startsWith(head), isTrue, reason: reason);
            expect(pasted.text.endsWith(tail), isTrue, reason: reason);
            // Typing gives the same field unless the whole insert fit at
            // once while some code point of it, on its own, ran over (one
            // that later ones join to the text after it).
            final typed = _type(f, start, insert);
            if (typed.text != pasted.text) {
              expect(
                m(head + insert + tail),
                lessThanOrEqualTo(limit),
                reason: reason,
              );
              expect(pasted.text, head + insert + tail, reason: reason);
            }
          }
        });
      }
    }
  });

  group('UIFLOW-R19-01: the counter shows room exactly when a letter typed '
      'at the end goes in', () {
    test('line breaks and spaces at the end count once a letter would '
        'follow them, up to the cap', () {
      final f = TextCapFormatter(10);
      int c(String s) => TextCapFormatter.counted(s, 10);
      expect(c('a' * 8), 8);
      expect(c('${'a' * 8}\n'), 9);
      expect(c('${'a' * 8}\n\n'), 10);
      expect(c('${'a' * 8}  '), 10);
      expect(c('${'a' * 8}\r\n'), 9);
      // A full note may end with more breaks: they take no room while
      // nothing follows them, and the counter stays at the cap.
      expect(c('${'a' * 10}\n\n\n'), 10);
      // Leading spaces and breaks, and hidden characters, take no room.
      expect(c('\n\n  ${'a' * 3}'), 3);
      expect(c('${'a' * 3}\u200B\u200E'), 3);
      expect(c('   '), 0);
      // A held note over the cap shows its length.
      expect(c('a' * 12), 12);
      final eight = _at('${'a' * 8}\n\n', 10);
      expect(_type(f, eight, 'b').text, eight.text);
      final nine = _at('${'a' * 8}\n', 9);
      expect(_type(f, nine, 'b').text, '${'a' * 8}\nb');
    });

    for (final seed in List.generate(6, (i) => 1900 + i)) {
      for (final multiline in [true, false]) {
        test('seed $seed, multiline $multiline', () {
          final r = Random(seed);
          const ends = [' ', '\n', '\r\n', '\r', '\t', '\u2028', '\u200B'];
          for (var i = 0; i < 400; i++) {
            final limit = 1 + r.nextInt(30);
            final f = TextCapFormatter(limit, multiline: multiline);
            final b = StringBuffer(_random(r, r.nextInt(40)));
            for (var k = r.nextInt(5); k > 0; k--) {
              b.write(ends[r.nextInt(ends.length)]);
            }
            final text = b.toString();
            final stored = TextClean.clean(text, multiline: multiline);
            // Over the Ledger's code units the field says it is too long
            // (and counts the code units): not what this measures.
            if (TextCap.length(stored) > limit &&
                stored.characters.length <= limit) {
              continue;
            }
            final shown = TextCapFormatter.counted(
              text,
              limit,
              multiline: multiline,
            );
            final reason = 'limit $limit, text ${text.runes.toList()}';
            expect(
              shown,
              greaterThanOrEqualTo(TextCap.length(stored)),
              reason: reason,
            );
            expect(
              shown,
              lessThanOrEqualTo(max(limit, TextCap.length(stored))),
              reason: reason,
            );
            for (final letter in const ['b', '7', '中']) {
              final v = _at(text, text.length);
              final typed = _type(f, v, letter).text;
              final went = typed == text + letter;
              if (!went) expect(typed, text, reason: '$reason, $letter');
              expect(went, shown < limit, reason: '$reason, $letter');
            }
          }
        });
      }
    }
  });

  test('a paste of 20,000 characters into a nearly full note is quick', () {
    final f = TextCapFormatter(1000);
    final held = '${'x' * 990}\n${'y' * 5}';
    final paste = List.filled(5000, 'a\u200B b\u0301').join();
    final watch = Stopwatch()..start();
    final out = _paste(f, _at(held, 500), paste);
    watch.stop();
    expect(_len(out.text), 1000);
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });
}
