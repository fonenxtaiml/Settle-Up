// NormalForm gives the forms unorm_dart gives, character for character, in
// time linear in the text (DATA-R15-01). Property tests: every code point
// alone, and seeded random texts drawn from every class that decomposition,
// ordering or composition treats specially.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/normal_form.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../support/cpu_clock.dart' show cpuMicrosPer;

String _hex(String s) => s.runes
    .map((r) => r.toRadixString(16).toUpperCase().padLeft(4, '0'))
    .join(' ');

/// Code points by class: ASCII, precomposed and singletons, marks of many
/// combining classes (some that decompose to several marks), characters
/// NFKC expands, Hangul jamo and syllables, pairs of starters that compose
/// (Indic two-part vowels), composition exclusions, emoji, invisibles,
/// lone surrogates and code points no table lists.
const List<int> _pool = [
  0x41, 0x61, 0x65, 0x78, 0x20, 0x2E, 0x31, 0x3B, //
  0xA0, 0xA8, 0xAA, 0xB4, 0xBD, 0xC5, 0xE9, 0x1E09, 0x1EC7, 0x212B, 0x2126,
  0x300, 0x301, 0x302, 0x308, 0x316, 0x323, 0x327, 0x334, 0x340, 0x343,
  0x344, 0x345, 0x5B0, 0x5B8, 0x651, 0x93C, 0x94D, 0xF71, 0xF72, 0xF73,
  0xF74, 0xF75, 0xF77, 0xF79, 0xF80, 0xF81, 0xFB2, 0xFB3, 0x1D165, 0x1D167,
  0x1D16E, 0xFF9E, 0xFF9F, 0x20E3, 0x3099, 0x309A, //
  0xFDFA, 0xFDFB, 0x337F, 0x3300, 0x2026, 0x2474, 0xFB01, 0x1D15E, 0x1D160,
  0xFF21, 0x33FF, 0x2163, 0xFB2C, 0x1D400, 0x2ADC, 0x958, 0xF43, //
  0x1100, 0x1112, 0x1113, 0x1161, 0x1175, 0x11A7, 0x11A8, 0x11C2, 0xAC00,
  0xAC01, 0xD7A3, 0xD7A4, 0x3131, 0x314F, 0xFFA0, 0xFFC2, 0x115F, 0x1160,
  0x3164, //
  0xB47, 0xB3E, 0xB56, 0xB57, 0xBC6, 0xBBE, 0xBD7, 0xCC6, 0xCC2, 0xCD5,
  0xD46, 0xD3E, 0xD57, 0xDD9, 0xDCF, 0xDCA, 0xDDF, 0x1025, 0x102E, 0x1B05,
  0x1B35, 0x11099, 0x110BA, 0x11131, 0x11127, 0x1133E, 0x11347, 0x30AB,
  0x304B, //
  0x1F469, 0x1F4BB, 0x2764, 0xFE0F, 0x200D, 0x200B, 0xAD, 0x2060, //
  0xD800, 0xDBFF, 0xDC00, 0xE000, 0xFFFF, 0x10FFFF, 0x4E00, 0xA66F, 0x3400,
];

String _random(Random rnd, int maxRunes) {
  final b = StringBuffer();
  final n = 1 + rnd.nextInt(maxRunes);
  var count = 0;
  while (count < n) {
    final r = _pool[rnd.nextInt(_pool.length)];
    // Sometimes one code point many times, so long runs of marks form.
    final rep = rnd.nextInt(5) == 0 ? 1 + rnd.nextInt(80) : 1;
    for (var k = 0; k < rep && count < n; k++, count++) {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

void _same(String s) {
  expect(NormalForm.nfc(s), unorm.nfc(s), reason: 'NFC ${_hex(s)}');
  expect(NormalForm.nfd(s), unorm.nfd(s), reason: 'NFD ${_hex(s)}');
  expect(NormalForm.nfkc(s), unorm.nfkc(s), reason: 'NFKC ${_hex(s)}');
  expect(NormalForm.nfkd(s), unorm.nfkd(s), reason: 'NFKD ${_hex(s)}');
}

void main() {
  test('every code point alone has the forms unorm_dart gives', () {
    final bad = <String>[];
    for (var r = 0; r <= 0x10FFFF; r++) {
      // Unassigned planes 4-13 hold nothing any table lists.
      if (r == 0x40000) r = 0xE0000;
      final s = String.fromCharCode(r);
      if (NormalForm.nfkc(s) != unorm.nfkc(s) ||
          NormalForm.nfc(s) != unorm.nfc(s) ||
          NormalForm.nfkd(s) != unorm.nfkd(s) ||
          NormalForm.nfd(s) != unorm.nfd(s)) {
        bad.add(r.toRadixString(16));
        if (bad.length > 10) break;
      }
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('every code point after a letter, a mark and a jamo, and before a '
      'mark, has the forms unorm_dart gives', () {
    final bad = <String>[];
    for (var r = 0xA0; r <= 0x2FFFF; r++) {
      if (r == 0x3400) r = 0xA000; // CJK ideographs: no decompositions
      if (r == 0xD800) r = 0xE000;
      final c = String.fromCharCode(r);
      for (final s in ['a$c', '́$c', 'ᄀ$c', '가$c', '$c̣']) {
        if (NormalForm.nfkc(s) != unorm.nfkc(s) ||
            NormalForm.nfc(s) != unorm.nfc(s)) {
          bad.add(_hex(s));
        }
      }
      if (bad.length > 10) break;
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('every character that composes with the one before it is known as '
      'one that may', () {
    final missing = <String>[];
    for (var r = 0; r <= 0x10FFFF; r++) {
      if (r == 0x40000) r = 0xE0000;
      final s = String.fromCharCode(r);
      // r composes with the character before it when NFC of the
      // decomposition of some character ends by joining r to it.
      final d = unorm.nfd(s).runes.toList();
      if (d.length < 2) continue;
      // The last character of a canonical decomposition is the second of
      // the composition that makes it, when one does.
      if (unorm.nfc(s) != s) continue; // excluded: never composed
      if (!NormalForm.joinsPrevious(d.last)) missing.add(d.last.toRadixString(16));
    }
    expect(missing, isEmpty);
    // And every composition unorm_dart makes of two characters is made.
    for (final second in NormalForm.startersThatCompose) {
      expect(NormalForm.joinsPrevious(second), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('property: seeded random texts of every class have the forms '
      'unorm_dart gives', () {
    final rnd = Random(1517);
    for (var i = 0; i < 6000; i++) {
      _same(_random(rnd, i.isEven ? 12 : 400));
    }
  });

  test('long runs of marks of falling and mixed classes are ordered as '
      'unorm_dart orders them', () {
    final cases = [
      List.generate(300, (i) => const ['ͅ', '́', '̖', '̴'][i % 4]).join(),
      List.generate(300, (i) => i.isEven ? '́' : '̖').join(),
      '̈́' * 158,
      'ཷ' * 238,
      'ཱི' * 100,
      '\u{1D165}\u{1D16E}' * 80,
    ];
    for (final marks in cases) {
      _same('x$marks');
      _same('ᄀ$marks');
      _same(marks);
      _same('a${marks}b$marks');
    }
  });

  test('time is linear in the text, whatever runs of marks it holds', () {
    // Warm the tables.
    NormalForm.nfkc('x${'ཷ' * 10}${'̈́' * 10}');
    // The CPU time of a call: the fastest of three windows of at least
    // 40 ms, so the load of the full suite does not decide (DATA-R21-01).
    double micros(String s) =>
        cpuMicrosPer((_) => NormalForm.nfkc(s), warmUp: 3, minCalls: 20);

    final small = 'x${'ཷ' * 200}';
    final large = 'x${'ཷ' * 3200}';
    final ts = micros(small), tl = micros(large);
    // 16 times the text: a quadratic cost would be 256 times.
    expect(tl, lessThan(max(48 * ts, 20000)), reason: '$ts us vs $tl us');
  });
}
