// UIFLOW-R8-01: a name field counts, caps and checks a name as it is
// stored (NameText.normalize, held to TextRules.tooLong by the Ledger and
// Settings), so no name the field holds is refused for its length on
// save. Seeded random names over the character classes that change
// length under normalisation, plus the reported ones.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

/// Pieces a random name is made of, one list per character class.
const _classes = <List<String>>[
  // Letters and digits.
  ['a', 'B', 'z', 'Q', '7', '0', 'ß', 'é', 'Ж', 'अ', 'क\u094D', 'ि', '中', '한'],
  // Characters NFKC makes longer.
  ['…', '½', '™', 'ﬁ', '㈜', 'ﷺ', '㎏', '①', 'Ⅻ', '⑽', '㍻', 'ﬃ', '¼', '℡'],
  // Characters NFKC makes shorter or changes: full width, compatibility.
  ['Ａ', 'ｂ', '１', 'ｶ', 'ﾞ', 'ℌ', '²', 'ſ'],
  // Spaces and fillers that become one space.
  [' ', '  ', '\t', '\u00A0', '\u2003', '\u3000', '\u3164', '\u1160', '\u115F', '\uFFA0', '\u2800'],
  // Characters that are left out.
  ['\u200B', '\u200C', '\u200D', '\u2060', '\u00AD', '\u200E', '\u202E', '\u2066', '\uFEFF', '\uFE0F', '\u034F'],
  // Combining marks and emoji sequences (several code units, one char).
  ['\u0301', '\u0308', '👩\u200D💻', '👨\u200D👩\u200D👧\u200D👦', '❤\uFE0F', '🇮🇳', '🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}', '1\uFE0F\u20E3'],
  // Symbols and punctuation.
  ['.', '-', '😎', '&', "'", '’', '/'],
];

String _randomName(Random rnd, int maxPieces) {
  final n = rnd.nextInt(maxPieces + 1);
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    final c = _classes[rnd.nextInt(_classes.length)];
    b.write(c[rnd.nextInt(c.length)]);
  }
  return b.toString();
}

bool _storedFits(String raw, int limit) =>
    TextRules.tooLong(NameText.normalize(raw), limit) == null;

TextEditingValue _at(String text, [int? cursor]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);

void main() {
  const limits = [kMemberNameMax, kGroupNameMax, 5];

  test('UIFLOW-R8-01: the reported names count as they are stored', () {
    const typed = 'Arjun Venkataraman Subramaniam Iyer Jr…';
    expect(typed.characters.length, 39);
    expect(NameLimit.length(typed), 41);
    expect(NameLimit.fits(typed, kMemberNameMax), isFalse);
    expect(nameInputError(typed, limit: kMemberNameMax), S.errTooLong);
    expect(isSavableName(typed, kMemberNameMax), isFalse);
    for (final c in ['½', '™', 'ﬁ', '㈜', 'ﷺ']) {
      final raw = 'A' * (kMemberNameMax - 1) + c;
      expect(raw.characters.length, kMemberNameMax);
      expect(
        NameLimit.fits(raw, kMemberNameMax),
        _storedFits(raw, 40),
        reason: c,
      );
      expect(_storedFits(raw, 40), isFalse, reason: c);
    }
    // A 60-character group name ending in "…" is 62 once stored.
    final group = '${'G' * 59}…';
    expect(NameLimit.fits(group, kGroupNameMax), isFalse);
  });

  test('UIFLOW-R8-01: emoji with many code units count against the code '
      'unit cap the save applies', () {
    final family = '👨\u200D👩\u200D👧\u200D👦' * 15; // 15 characters, 165 code units
    expect(family.characters.length, 15);
    expect(_storedFits(family, 40), isFalse);
    expect(NameLimit.fits(family, 40), isFalse);
    expect(NameLimit.fits('👨\u200D👩\u200D👧\u200D👦' * 14, 40), isTrue);
  });

  test('property: a name the field counts as fitting always fits once '
      'stored, and a stored name fits exactly when the save accepts it', () {
    final rnd = Random(20261110);
    for (var i = 0; i < 6000; i++) {
      final raw = _randomName(rnd, 70);
      final stored = NameText.normalize(raw);
      for (final limit in limits) {
        if (NameLimit.fits(raw, limit)) {
          expect(_storedFits(raw, limit), isTrue, reason: '$raw / $limit');
          expect(
            nameInputError(raw, limit: limit),
            NameText.isValid(raw) || raw.trim().isEmpty
                ? isNull
                : S.nameNeedsLetter,
          );
        } else {
          expect(isSavableName(raw, limit), isFalse);
        }
        if (NameText.normalize(stored) == stored) {
          expect(
            NameLimit.fits(stored, limit),
            _storedFits(stored, limit),
            reason: '$stored / $limit',
          );
        }
        expect(
          NameLimit.length(raw),
          greaterThanOrEqualTo(stored.characters.length),
        );
      }
    }
  });

  test('property: fit keeps the longest start of the name that fits', () {
    final rnd = Random(7);
    for (var i = 0; i < 3000; i++) {
      final raw = _randomName(rnd, 80);
      for (final limit in limits) {
        final f = NameLimit.fit(raw, limit);
        expect(raw.startsWith(f), isTrue);
        expect(NameLimit.fits(f, limit), isTrue, reason: '$raw / $limit');
        if (f != raw) {
          final next = raw.characters.take(f.characters.length + 1).join();
          expect(NameLimit.fits(next, limit), isFalse, reason: raw);
        }
      }
    }
  });

  test('property: the formatter never leaves a name that does not fit, '
      'keeps every edit that fits, and pasting equals typing', () {
    final rnd = Random(42);
    for (var i = 0; i < 2500; i++) {
      final limit = limits[rnd.nextInt(limits.length)];
      final f = NameLengthFormatter(limit);
      final start = NameLimit.fit(_randomName(rnd, 60), limit);
      // Insert at a whole-character boundary.
      final chars = start.characters.toList();
      final cut = rnd.nextInt(chars.length + 1);
      final head = chars.take(cut).join();
      final tail = chars.skip(cut).join();
      final insert = _randomName(rnd, 30);
      final old = _at(start, head.length);
      final pasted = f.formatEditUpdate(
        old,
        _at(head + insert + tail, head.length + insert.length),
      );
      expect(NameLimit.fits(pasted.text, limit), isTrue);
      if (NameLimit.fits(head + insert + tail, limit)) {
        expect(pasted.text, head + insert + tail);
      }
      expect(pasted.text.endsWith(tail), isTrue);
      expect(pasted.text.startsWith(head), isTrue);
      // The same text typed one character at a time at the same place.
      var value = _at(head + tail, head.length);
      for (final c in insert.characters) {
        final cur = value.selection.baseOffset;
        final t = value.text;
        value = f.formatEditUpdate(
          value,
          _at(t.substring(0, cur) + c + t.substring(cur), cur + c.length),
        );
      }
      expect(pasted.text, value.text, reason: 'paste "$insert" into "$start"');
      expect(pasted.selection.baseOffset, value.selection.baseOffset);
    }
  });

  test('the formatter lets a composing word run over and cuts it when the '
      'composition ends', () {
    final f = NameLengthFormatter(3);
    const composing = TextEditingValue(
      text: 'abcd',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 2, end: 4),
    );
    expect(f.formatEditUpdate(_at('ab'), composing), composing);
    final done = f.formatEditUpdate(composing, _at('abcd'));
    expect(done.text, 'abc');
    expect(nameInputError('abcd', limit: 3), S.errTooLong);
  });

  test('plain text is cut where the default length cap cuts it; a '
      'character that grows past the limit is refused', () {
    final f = NameLengthFormatter(5);
    expect(f.formatEditUpdate(_at(''), _at('abcdefg')).text, 'abcde');
    expect(f.formatEditUpdate(_at('abc'), _at('ab…c', 3)).text, 'abc');
    expect(f.formatEditUpdate(_at('ab'), _at('ab…')).text, 'ab…');
    expect(f.formatEditUpdate(_at('abc'), _at('abc…')).text, 'abc');
  });
}
