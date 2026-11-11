// QA DATA-R17: correctness probes of the DATA-R15-01 fix (NameText skips
// NFKC/NFC for stable text and normalises a bounded head of a long name).
// fit and normalize must give exactly what normalising all of a name gives
// (fitReference / normalizeReference) on adversarial input.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Code points chosen for the edge cases of the fast paths.
const pool = <int>[
  0x41, 0x61, 0x20, 0x09, 0x2E, 0x31, // ASCII
  0xE9, 0xA8, 0xB4, 0xC5, 0x212B, 0x2126, // precomposed / singletons
  0x301, 0x308, 0x323, 0x327, 0x344, 0x345, 0x93C, 0x94D, 0x0F71, 0x0F77,
  0x0F80, 0x0FB2, 0x05B0, 0x0E31, // marks
  0xFDFA, 0xFDFB, 0x337F, 0x3300, 0x2026, 0x2474, 0xFB01, 0x1D15E, // expand
  0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0x3131, 0x314F, 0xFFA0, 0xFFC2,
  0x115F, 0x1160, 0x3164, // Hangul
  0x0B47, 0x0B3E, 0x0B57, 0x0DD9, 0x0DCF, 0x0DCA, 0x0CC6, 0x0CC2, 0x0CD5,
  0x1025, 0x102E, 0x0D46, 0x0D3E, 0x0BC6, 0x0BBE, 0x1B05, 0x1B35, // pairs
  0x11099, 0x110BA, 0x11131, 0x11127, 0x1133E, 0x11347, // astral pairs
  0x0628, 0x0644, 0x0915, 0x0937, 0x200D, 0x200C, 0x200B, 0x00AD, 0x061C,
  0xFE0F, 0xFE0E, 0x1F469, 0x1F4BB, 0x2764, 0x1F3F4, 0xE0067, 0xE007F,
  0x20E3, // joiners, emoji, tags
  0x3000, 0x2003, 0x00A0, 0x2800, 0x2028, 0x7F, 0x85, 0xFEFF, // spaces etc
  0xD800, 0xDC00, // lone surrogates
  0x0958, 0x2ADC, 0x1D160, 0x0F43, // composition exclusions
];

String randomName(Random rnd, int maxUnits) {
  final b = StringBuffer();
  final n = rnd.nextInt(maxUnits) + 1;
  // Runs: sometimes one char repeated, sometimes random from the pool.
  while (b.length < n) {
    final r = pool[rnd.nextInt(pool.length)];
    final rep = rnd.nextInt(4) == 0 ? rnd.nextInt(60) + 1 : 1;
    for (var i = 0; i < rep && b.length < n; i++) {
      b.writeCharCode(r);
    }
  }
  final s = b.toString();
  return s.length > maxUnits ? s.substring(0, maxUnits) : s;
}

void main() {
  test('QA DATA-R17 probe: fit == fitReference and normalize == normalizeReference on '
      'random adversarial names', () {
    final rnd = Random(17);
    final bad = <String>[];
    for (var i = 0; i < 40000; i++) {
      final limit = i.isEven ? NameText.maxLength : NameText.maxGroupLength;
      final s = randomName(rnd, limit * NameText.unitsPerChar);
      final f = NameText.fit(s, limit);
      final fr = NameText.fitReference(s, limit);
      final n = NameText.normalize(s);
      final nr = NameText.normalizeReference(s);
      if (f != fr || n != nr) {
        bad.add(s.runes.map((r) => r.toRadixString(16)).join(' '));
        if (bad.length > 5) break;
      }
    }
    expect(bad, isEmpty);
  });

  test('QA DATA-R17 probe: every canonical pair that composes is normalised as NFC '
      'does (no stable pair is skipped wrongly)', () {
    final bad = <String>[];
    for (var c = 0xA0; c <= 0x10FFFF; c++) {
      if (c >= 0xD800 && c <= 0xDFFF) continue;
      final s = String.fromCharCode(c);
      final d = unorm.nfd(s).runes.toList();
      if (d.length != 2) continue;
      final pair = String.fromCharCodes(d);
      for (final t in ['x$pair', pair, '${pair}y']) {
        if (NameText.normalize(t) != NameText.normalizeReference(t)) {
          bad.add(d.map((r) => r.toRadixString(16)).join('+'));
        }
      }
    }
    expect(bad, isEmpty);
  });

  test(
    'QA DATA-R17 probe: every BMP and astral char alone and between letters',
    () {
      final bad = <String>[];
      for (var c = 0x80; c <= 0x10FFFF; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        if (c > 0x323AF && c < 0xE0000) continue; // unassigned planes
        final s = String.fromCharCode(c);
        for (final t in [s, 'a${s}b', '$ś', 'ᄀ$s']) {
          if (NameText.normalize(t) != NameText.normalizeReference(t)) {
            bad.add(c.toRadixString(16));
            break;
          }
        }
        if (bad.length > 20) break;
      }
      expect(bad, isEmpty);
    },
  );
}
