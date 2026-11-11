// QA UIFLOW round 19: an independent property probe of TextCapFormatter
// after the UIFLOW-R18-01 fix (hidden characters take no room in the notes
// and description caps). The reference below is written from the
// formatter's contract only: an edit that fits passes; of one that runs
// over, each inserted code point is kept when the stored text
// (TextClean.clean, multiline, then characters) after it is within the
// limit, or no longer than before it. The alphabet stresses what the
// formatter's incremental measure has to get right: hidden characters,
// CR/LF pairs split across the edit, trimmed ends, combining marks, ZWJ
// emoji, skin tones, flags, Hangul jamo, prepended marks and Indic
// conjuncts.
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/ui/format/text_cap_formatter.dart';

int _stored(String s) => TextClean.clean(s, multiline: true).characters.length;

const _pieces = <String>[
  'a', 'b', 'Z', '7', ' ', '  ', '\t', '\n', '\r', '\r\n', '\u0085',
  '\u{2028}', '\u{2029}', '\u000B', '\u000C',
  '\u{200B}',
  '\u{200E}',
  '\u{200F}',
  '\u{202A}',
  '\u{202E}',
  '\u{2066}',
  '\u{2069}',
  '\u{61C}', '\u{2060}', '\u{FEFF}', '\u{FFF9}', '\u0007', '\u009B', '\u{A0}',
  '\u{3000}',
  '\u{200D}',
  '\u{200C}',
  '\u{301}',
  '\u{302}',
  '\u{FE0F}',
  '\u{34F}',
  '\u{1F468}', '\u{1F3FD}', '\u{1F1EE}', '\u{1F1F3}', '\u{1F1FA}',
  '\u{1100}', '\u{1161}', '\u{11A8}', '\u{AC00}', // Hangul L, V, T, LV
  '\u{600}', '\u{915}', '\u{94D}', '\u{93F}', // prepend, ka, virama, vowel sign
  '\u{E0067}', '\u{1F3F4}', // tag, black flag
];

String _randomText(math.Random rnd, int maxPieces) {
  final n = rnd.nextInt(maxPieces + 1);
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    b.write(_pieces[rnd.nextInt(_pieces.length)]);
  }
  return b.toString();
}

/// The contract, measured on the whole text for every code point.
/// An edit of which nothing is kept is refused whole: a replaced
/// selection stays ([removed]).
String _reference(
  String head,
  String removed,
  String inserted,
  String tail,
  int limit,
) {
  if (_stored(head + inserted + tail) <= limit) return head + inserted + tail;
  var kept = '';
  var count = _stored(head + tail);
  for (final r in inserted.runes) {
    final c = String.fromCharCode(r);
    final n = _stored(head + kept + c + tail);
    if (n <= math.max(limit, count)) {
      kept += c;
      count = n;
    }
  }
  return kept.isEmpty ? head + removed + tail : head + kept + tail;
}

void main() {
  test('R19 probe (UIFLOW-R18-01 class): the formatter agrees with the '
      'whole-text measure for 40,000 random inserts and replacements near '
      'small caps', () {
    final rnd = math.Random(190119);
    final mismatches = <String>[];
    for (var i = 0; i < 40000 && mismatches.length < 5; i++) {
      final limit = 1 + rnd.nextInt(8);
      final head = _randomText(rnd, 8);
      final tail = _randomText(rnd, 8);
      var inserted = _randomText(rnd, 10);
      if (inserted.isEmpty) inserted = 'x';
      // Replaced text whose first code unit differs from the insert's, so
      // the formatter's split finds the same head.
      final removed = rnd.nextBool() ? '' : _randomText(rnd, 3);
      final oldText = head + removed + tail;
      final insertedFirst = inserted.codeUnitAt(0);
      if (removed.isNotEmpty && removed.codeUnitAt(0) == insertedFirst) {
        continue;
      }
      final newText = head + inserted + tail;
      final out = TextCapFormatter(limit).formatEditUpdate(
        TextEditingValue(
          text: oldText,
          selection: TextSelection.collapsed(offset: head.length),
        ),
        TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: head.length + inserted.length,
          ),
        ),
      );
      final want = _reference(head, removed, inserted, tail, limit);
      if (out.text != want) {
        mismatches.add(
          'limit $limit head ${_esc(head)} ins ${_esc(inserted)} '
          'tail ${_esc(tail)}: got ${_esc(out.text)} want ${_esc(want)}',
        );
      }
      // Whatever it keeps, the stored text never runs over the cap or what
      // the field holds without the insert (or the edit is refused whole).
      expect(
        out.text == oldText ||
            _stored(out.text) <= math.max(limit, _stored(head + tail)),
        isTrue,
      );
    }
    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });

  test('R19 probe (UIFLOW-R18-01 class): typing a text one code point at a '
      'time keeps what pasting it keeps', () {
    final rnd = math.Random(19);
    for (var i = 0; i < 3000; i++) {
      final limit = 1 + rnd.nextInt(6);
      final text = _randomText(rnd, 14);
      final f = TextCapFormatter(limit);
      final pasted = f
          .formatEditUpdate(
            TextEditingValue.empty,
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
          )
          .text;
      var typed = TextEditingValue.empty;
      for (final r in text.runes) {
        final t = typed.text + String.fromCharCode(r);
        typed = f.formatEditUpdate(
          typed,
          TextEditingValue(
            text: t,
            selection: TextSelection.collapsed(offset: t.length),
          ),
        );
      }
      expect(typed.text, pasted, reason: 'limit $limit text ${_esc(text)}');
    }
  });

  test('R19 probe (UIFLOW-R18-01 class): each hidden character of '
      'TextClean.isHidden takes no room at the 1000 cap', () {
    final f = TextCapFormatter(1000);
    final hidden = <int>[
      for (var r = 0; r < 0x20; r++)
        if (!TextClean.isBreak(r)) r,
      for (var r = 0x7F; r <= 0x9F; r++)
        if (r != 0x85) r,
      0x061C,
      0x200B,
      0x200E,
      0x200F,
      0x202A,
      0x202B,
      0x202C,
      0x202D,
      0x202E,
      0x2060,
      0x2066,
      0x2067,
      0x2068,
      0x2069,
      0xFEFF,
      0xFFF9,
      0xFFFA,
      0xFFFB,
    ];
    for (final h in hidden) {
      expect(TextClean.isHidden(h), isTrue);
      final c = String.fromCharCode(h);
      final pasted = List.filled(1000, 'a$c').join();
      final out = f.formatEditUpdate(
        TextEditingValue.empty,
        TextEditingValue(
          text: pasted,
          selection: TextSelection.collapsed(offset: pasted.length),
        ),
      );
      expect(out.text, pasted, reason: 'U+${h.toRadixString(16)}');
      final more = '${out.text}b';
      final typed = f.formatEditUpdate(
        out,
        TextEditingValue(
          text: more,
          selection: TextSelection.collapsed(offset: more.length),
        ),
      );
      expect(typed.text, out.text, reason: 'the 1001st letter is refused');
    }
  });
}

String _esc(String s) => s.runes
    .map(
      (r) => r >= 0x21 && r < 0x7F
          ? String.fromCharCode(r)
          : '<${r.toRadixString(16)}>',
    )
    .join();
