// NameText.normalize skips NFC when a clean-up pass changes only spaces or
// leaves out a character before one that composes with nothing before it,
// and skips the confirming pass when NFC would change nothing (DATA-R15-01).
// Property tests: on seeded random names drawn from every class those
// shortcuts reason about, normalize and fit give exactly what the full
// definition gives (normalizeReference, fitReference), and what normalize
// gives is in NFC and NFKC as unorm_dart computes them.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/normal_form.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

String _hex(String s) => s.runes
    .map((r) => r.toRadixString(16).toUpperCase().padLeft(4, '0'))
    .join(' ');

/// Characters by the class the shortcuts reason about.
const Map<String, List<int>> _classes = {
  // Every character that draws as a space, and the plain space.
  'space': [
    0x20, 0x09, 0x0A, 0x0D, 0x85, 0xA0, 0x1680, 0x2000, 0x2007, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0x115F, 0x1160, 0x3164, 0xFFA0,
    0x2800, //
  ],
  // Characters a pass leaves out, or keeps next to the right neighbours.
  'invisible': [
    0x00AD, 0x034F, 0x061C, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x2060,
    0x2066, 0x202E, 0xFEFF, 0xFE0E, 0xFE0F, 0x1D173, 0xE0067, 0xE007F, 0x07,
    0x7F, 0x9F, 0xD800, 0xDC00, //
  ],
  // Non-starters of several classes, and characters NFKC makes marks.
  'mark': [
    0x0300, 0x0301, 0x0308, 0x0316, 0x0323, 0x0327, 0x0334, 0x0344, 0x0345,
    0x05B0, 0x064B, 0x093C, 0x094D, 0x0F71, 0x0F72, 0x0F73, 0x0F75, 0x0F77,
    0x0F80, 0x1D165, 0x1D16E, 0x20E3, 0x3099, 0xFF9E, //
  ],
  // Starters that compose with the character before them.
  'second': [
    0x1161, 0x1175, 0x11A8, 0x11C2, 0x0B3E, 0x0B56, 0x0B57, 0x0BBE, 0x0BD7,
    0x0CC2, 0x0CD5, 0x0D3E, 0x0D57, 0x0DCF, 0x0DDF, 0x102E, 0x1B35, 0x09BE,
    0x09D7, 0x1133E, //
  ],
  // What they compose with, and letters that compose with marks.
  'first': [
    0x61, 0x65, 0x41, 0x55, 0x1100, 0x1112, 0xAC00, 0x0B47, 0x0BC6, 0x0CC6,
    0x0D46, 0x0DD9, 0x1025, 0x1B05, 0x09C7, 0x11347, 0x0915, 0x0628, 0x304B,
    0x0FB2, 0x0FB3, //
  ],
  // Others: precomposed, expanding, emoji, ASCII punctuation.
  'other': [
    0xE9, 0x1EC7, 0x212B, 0xFDFA, 0x337F, 0x2026, 0xFB01, 0x1F469, 0x1F4BB,
    0x2764, 0x1F3F4, 0x23, 0x2E, 0x31, 0x4E2D, 0x05D0, //
  ],
};

String _random(Random rnd, int maxUnits) {
  final names = _classes.keys.toList();
  final picked = [
    for (var i = 0; i < 2 + rnd.nextInt(3); i++)
      _classes[names[rnd.nextInt(names.length)]]!,
  ];
  final b = StringBuffer();
  final target = 1 + rnd.nextInt(maxUnits);
  while (b.length < target) {
    final pool = picked[rnd.nextInt(picked.length)];
    final r = pool[rnd.nextInt(pool.length)];
    final rep = rnd.nextInt(6) == 0 ? 1 + rnd.nextInt(20) : 1;
    for (var k = 0; k < rep; k++) {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

void _check(String s, int limit) {
  final n = NameText.normalize(s);
  expect(n, NameText.normalizeReference(s), reason: _hex(s));
  expect(unorm.nfc(n), n, reason: 'NFC ${_hex(s)}');
  expect(NameText.normalize(n), n, reason: 'idempotent ${_hex(s)}');
  expect(
    NameText.fit(s, limit),
    NameText.fitReference(s, limit),
    reason: 'fit ${_hex(s)}',
  );
}

void main() {
  test('property: seeded random names of spaces, invisibles, marks and '
      'characters that compose give what the full definition gives', () {
    final rnd = Random(1501);
    for (var i = 0; i < 12000; i++) {
      final limit = i.isEven ? NameText.maxLength : NameText.maxGroupLength;
      _check(
        _random(rnd, i % 3 == 0 ? 24 : limit * NameText.unitsPerChar),
        limit,
      );
    }
  });

  test('every character left out, before every character of every class, '
      'after every first, gives what the full definition gives', () {
    for (final first in [..._classes['first']!, 0x20]) {
      for (final gone in _classes['invisible']!) {
        for (final next in [for (final c in _classes.values) ...c]) {
          final f = String.fromCharCode(first);
          final g = String.fromCharCode(gone);
          final x = String.fromCharCode(next);
          _check('$f$g$x', NameText.maxLength);
          _check('$f́$g$x', NameText.maxLength);
          _check('$f $g$x', NameText.maxLength);
        }
      }
    }
  });

  test('a space and every character that draws as one composes with no '
      'character before or after it', () {
    for (final space in _classes['space']!) {
      final s = String.fromCharCode(space);
      expect(NormalForm.joinsPrevious(space), isFalse, reason: _hex(s));
      for (final c in [
        ..._classes['mark']!,
        ..._classes['second']!,
        ..._classes['first']!,
      ]) {
        final x = String.fromCharCode(c);
        // Nothing composes with it, as the first character or the second.
        expect(unorm.nfc('$s$x'), unorm.nfc(s) + unorm.nfc(x), reason: _hex(s));
        expect(unorm.nfc('$x$s'), unorm.nfc(x) + unorm.nfc(s), reason: _hex(s));
      }
    }
  });

  test(
    'characters that draw nothing are starters and compose with nothing',
    () {
      for (final gone in _classes['invisible']!) {
        if (gone >= 0xD800 && gone <= 0xDFFF) continue;
        final g = String.fromCharCode(gone);
        expect(NormalForm.combiningClass(gone), 0, reason: _hex(g));
        expect(NormalForm.joinsPrevious(gone), isFalse, reason: _hex(g));
        for (final c in [for (final p in _classes.values) ...p]) {
          final x = String.fromCharCode(c);
          expect(
            unorm.nfc('$g$x'),
            unorm.nfc(g) + unorm.nfc(x),
            reason: _hex(g),
          );
        }
      }
    },
  );
}
