// isNameAsOpened (UIFLOW-R21-01): a name prompt saved with the name it
// opened with, or with a text that saves as that same name, is no rename.
// Properties over the character classes, with seeded random names:
// - the opened name itself, and the opened name with any mix of Unicode
//   spaces, format (Cf) and invisible filler characters added at the ends
//   or between its words, is "as opened";
// - a name whose saved form differs (a letter changed, added or removed,
//   a different case) is never "as opened";
// - a text that saves as no name at all is never "as opened" with a real
//   name, so the prompt still refuses it as a name.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/ui/screens/common.dart';

/// Unicode spaces (Zs and the line/paragraph separators).
const _spaces = [
  0x0020, 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, //
  0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
  0x3000,
];

/// Format (Cf) and bidi controls, and characters that draw nothing.
const _invisible = [
  0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, //
  0x202D, 0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067,
  0x2068, 0x2069, 0xFEFF,
];

/// Filler characters that show as a blank: Hangul fillers, Braille blank.
const _fillers = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800];

const _letters =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    'éñüßøçअआकखगमराजदेवनागरीதமிழ்عربي中文日本語한국어';

String _word(Random r) {
  final chars = _letters.runes.toList();
  final n = 1 + r.nextInt(6);
  return String.fromCharCodes([
    for (var i = 0; i < n; i++) chars[r.nextInt(chars.length)],
  ]);
}

String _name(Random r) {
  final words = 1 + r.nextInt(3);
  return [for (var i = 0; i < words; i++) _word(r)].join(' ');
}

/// [n] random characters that save as nothing.
String _noise(Random r, int n) {
  final all = [..._spaces, ..._invisible, ..._fillers];
  return String.fromCharCodes([
    for (var i = 0; i < n; i++) all[r.nextInt(all.length)],
  ]);
}

/// [name] with noise at the ends and in the gaps between its words (each
/// gap keeps at least one plain space, so the words stay apart).
String _padded(Random r, String name) {
  final words = name.split(' ');
  final b = StringBuffer(_noise(r, r.nextInt(4)));
  for (var i = 0; i < words.length; i++) {
    if (i > 0) b.write('${_noise(r, r.nextInt(3))} ${_noise(r, r.nextInt(3))}');
    b.write(words[i]);
  }
  b.write(_noise(r, r.nextInt(4)));
  return b.toString();
}

void main() {
  const limit = kMemberNameMax;

  test('the opened name, and the same with nothing but spaces or invisible '
      'characters added, is as opened', () {
    final r = Random(2101);
    for (var i = 0; i < 2000; i++) {
      final opened = NameText.fit(_name(r), limit);
      if (opened.isEmpty) continue;
      expect(isNameAsOpened(opened, opened, limit), isTrue, reason: opened);
      final typed = _padded(r, opened);
      expect(
        NameText.fit(typed, limit),
        opened,
        reason: 'premise: ${typed.runes.map((c) => c.toRadixString(16))}',
      );
      expect(
        isNameAsOpened(typed, opened, limit),
        isTrue,
        reason: typed.runes.map((c) => c.toRadixString(16)).join(' '),
      );
    }
  });

  test('every single space, format or filler character added inside or at '
      'the ends of the name is no rename', () {
    for (final c in [..._spaces, ..._invisible, ..._fillers]) {
      final ch = String.fromCharCode(c);
      for (final typed in [
        'Arjun$ch',
        '${ch}Arjun',
        'Arjun$ch K',
        'Arjun $ch K',
      ]) {
        final opened = typed.contains('K') ? 'Arjun K' : 'Arjun';
        expect(
          isNameAsOpened(typed, opened, limit),
          isTrue,
          reason: 'U+${c.toRadixString(16)} in "$typed"',
        );
      }
    }
  });

  test('a compatibility form of the opened name is as opened', () {
    expect(isNameAsOpened('Ａｒｊｕｎ', 'Arjun', limit), isTrue);
    expect(isNameAsOpened('Arjun K', 'Arjun K', limit), isTrue);
  });

  test('a name whose saved form differs is never as opened', () {
    final r = Random(2102);
    for (var i = 0; i < 2000; i++) {
      final opened = NameText.fit(_name(r), limit);
      final other = NameText.fit(_name(r), limit);
      if (opened.isEmpty || other.isEmpty) continue;
      final typed = _padded(r, other);
      expect(
        isNameAsOpened(typed, opened, limit),
        NameText.fit(typed, limit) == opened,
        reason: '"$typed" vs "$opened"',
      );
    }
    expect(isNameAsOpened('arjun', 'Arjun', limit), isFalse);
    expect(isNameAsOpened('Arjun K', 'Arjun', limit), isFalse);
    expect(isNameAsOpened('Arju', 'Arjun', limit), isFalse);
    expect(isNameAsOpened('Arjun (Pune)', 'Arjun', limit), isFalse);
  });

  test('a text that saves as no name is never as a real opened name', () {
    final r = Random(2103);
    for (var i = 0; i < 500; i++) {
      final typed = _noise(r, 1 + r.nextInt(6));
      expect(isNameAsOpened(typed, 'Arjun', limit), isFalse);
    }
  });
}
