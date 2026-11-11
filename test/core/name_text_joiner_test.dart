// NameText around joiners and selectors (PLATFORM-R15-01): whether a ZWJ,
// ZWNJ or variation selector stays is decided by the character that is
// kept after it, not by the next code point, which may be an invisible
// one that is left out. Property tests over the classes involved: every
// code point NameText leaves out or keeps only between two others, the
// letters of each joining script range, emoji and keycap bases, spaces,
// and pairs NFC composes.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

String _hex(String s) => s.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

/// Every code point NameText treats as invisible (left out unless it
/// changes how its neighbours draw).
final List<int> _invisible = [
  for (var r = 0; r <= 0x10FFFF; r++)
    if ((r < 0xD800 || r > 0xDFFF) && NameText.isInvisible(r)) r,
];

const _joiners = [0x200C, 0x200D, 0xFE0E, 0xFE0F, 0x20E3];

/// The invisibles that sit inside joining script blocks or next to them,
/// and the ones the finding named.
const _scriptInvisibles = [
  0x0600,
  0x0601,
  0x0602,
  0x0603,
  0x0604,
  0x0605,
  0x061C,
  0x06DD,
  0x070F,
  0x0890,
  0x0891,
  0x08E2,
  0x17B4,
  0x17B5,
  0x180B,
  0x180C,
  0x180D,
  0x180E,
  0x180F,
  0x110BD,
  0x110CD,
  0x200B,
  0x200E,
  0x200F,
  0x2060,
  0x00AD,
  0x034F,
  0xE0067,
  0xE007F,
  0x1D173,
  0x1BCA0,
  0x13430,
  0xFEFF,
];

/// A letter or mark from each range in which ZWJ and ZWNJ join.
const _joining = [
  0x0627, 0x0628, 0x0644, 0x0653, 0x0710, 0x0780, 0x07CA, 0x0840, //
  0x0915, 0x094D, 0x0928, 0x093C, 0x0995, 0x0B95, 0x0D15, 0x0DA0,
  0x0F40, 0x1000, 0x1780, 0x17D2, 0x1820, 0xA8F2, 0x10A10, 0x11013,
  0x11083,
];

const _emoji = [0x1F469, 0x1F4BB, 0x2764, 0x1F3F4, 0x1F600, 0x23, 0x31];

const _other = [0x61, 0x52, 0x4E00, 0x0301, 0x2E, 0x2D, 0x0661];

const _blank = [0x20, 0x0A, 0x09, 0x3000, 0x3164, 0x2800, 0x115F];

void main() {
  test('the cases QA found: the joiner goes with the mark after it', () {
    final cases = {
      'ب‍؜': 'ب',
      'Ali ب‍؜': 'Ali ب',
      'ب‍؜ x': 'ب x',
      'क‌؀ a': 'क a',
      'क्‍឴': 'क्',
      'क‍᠋': 'क',
    };
    // Found by the fuzz below: once the ZWNJ is gone, NFC puts the nukta
    // before the acute accent, so the ZWJ no longer follows a Devanagari
    // mark and a second pass would leave it out.
    cases['\u0661\u0301\u200C\u{E02CD}\u093C\u200D\uFE0F\u{E0067}'
            '\u0661\uFE0F'] =
        '\u0661\u093C\u0301\u0661';
    cases.forEach((raw, want) {
      expect(NameText.normalize(raw), want, reason: _hex(raw));
      expect(NameText.fit(raw), want, reason: _hex(raw));
    });
  });

  test(
    'a joiner before a dropped invisible still joins what comes after it',
    () {
      // The ZWJ in a half form or Persian ZWNJ stays when an invisible that
      // is left out stands between it and the next letter, and that form
      // is stable.
      for (final m in _scriptInvisibles) {
        final hindi = 'क्‍${String.fromCharCode(m)}ष';
        expect(NameText.normalize(hindi), 'क्‍ष', reason: _hex(hindi));
        final persian = 'می‌${String.fromCharCode(m)}ر';
        expect(NameText.normalize(persian), 'می‌ر', reason: _hex(persian));
        final coder = '\u{1F469}‍${String.fromCharCode(m)}\u{1F4BB}';
        expect(
          NameText.normalize(coder),
          '\u{1F469}‍\u{1F4BB}',
          reason: _hex(coder),
        );
      }
      // A keycap keeps its selector across a left-out mark.
      expect(NameText.normalize('1️​⃣'), '1️⃣');
    },
  );

  test('a very long run of invisibles is fast and leaves nothing', () {
    final raw = 'Aliب${'‍؜' * 50000}';
    final sw = Stopwatch()..start();
    expect(NameText.normalize(raw), 'Aliب');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('seeded random names around joiners: normalize, fit and display are '
      'idempotent, and a kept joiner always has something to join', () {
    final rnd = Random(1516);
    final pools = <List<int>>[
      _joiners,
      _joiners,
      _scriptInvisibles,
      _invisible,
      _joining,
      _joining,
      _emoji,
      _other,
      _blank,
    ];
    for (var i = 0; i < 40000; i++) {
      final raw = String.fromCharCodes([
        for (var j = rnd.nextInt(10); j >= 0; j--) _pick(rnd, pools),
      ]);
      _check(raw);
    }
  });
}

int _pick(Random rnd, List<List<int>> pools) {
  final pool = pools[rnd.nextInt(pools.length)];
  return pool[rnd.nextInt(pool.length)];
}

void _check(String raw) {
  final why = _hex(raw);
  final n = NameText.normalize(raw);
  expect(NameText.normalize(n), n, reason: 'normalize: $why');
  for (final limit in [3, NameText.maxLength, NameText.maxGroupLength]) {
    final f = NameText.fit(raw, limit);
    expect(NameText.fit(f, limit), f, reason: 'fit $limit: $why');
    expect(NameText.display(f, limit), f, reason: 'display $limit: $why');
  }
  // What is kept of a joiner or selector is followed by a character that
  // is always kept: never the end, a space or another invisible.
  final rs = n.runes.toList();
  for (var k = 0; k < rs.length; k++) {
    if (rs[k] == 0x200C || rs[k] == 0x200D) {
      expect(k + 1 < rs.length, isTrue, reason: 'joiner at the end: $why');
      final next = rs[k + 1];
      expect(
        next != 0x20 && !NameText.isInvisible(next),
        isTrue,
        reason: 'joiner before ${next.toRadixString(16)}: $why',
      );
    }
  }
}
