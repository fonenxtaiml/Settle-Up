// NameText takes one clean-up pass (PLATFORM-R17-01): whether a ZWJ or
// ZWNJ stays is decided by the base characters (starters) around it, so
// the NFC that follows a pass, which reorders accents and composes a base
// with the accent after it, cannot change what the next pass decides.
// Before, a joiner was decided by the accent right before it, and some
// names lost one joiner per pass, each pass running NFC over the whole
// name: quadratic work. Property tests over the classes: every character
// NFC composes, accents of every combining class around joiners, and
// long cascades of joiners and accents.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:unorm_dart/src/uchar.dart' show UChar;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_name.dart';

String _hex(String s) => s.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

int _ccc(int r) =>
    r < 0x300 ? 0 : UChar.fromCharCode(r, true)!.getCanonicalClass();

/// Joiners, selectors and tags: the invisibles a name may keep.
const _joiners = [0x200C, 0x200D, 0x200C, 0x200D, 0xFE0F, 0xFE0E, 0xE0067];

/// Invisibles a name always leaves out.
const _dropped = [0x200B, 0x061C, 0x00AD, 0x2060, 0x180B, 0x17B4, 0xFEFF];

/// Bases: letters of joining scripts, emoji, keycap bases, other letters,
/// and starters that compose with the accent or vowel sign after them.
const _bases = [
  0x0915, 0x0937, 0x0928, 0x0995, 0x09C7, 0x0B47, 0x0DD9, 0x0628, //
  0x0627, 0x0648, 0x064A, 0x06D5, 0x0661, 0x1780, 0x0F40, 0x1000,
  0x1F469, 0x1F4BB, 0x2764, 0x1F3F4, 0x2190, 0x2192, 0x2194, 0x31,
  0x61, 0x65, 0x41, 0x3B1, 0x4E00, 0x1100, 0xAC00,
];

/// Accents of many combining classes (nukta 7, virama 9, Arabic 27 to 35,
/// below 220, above 230, overlay 1, ...) and vowel signs that are
/// starters but compose (U+09BE, U+0B3E, U+0DCF, U+1161).
const _accents = [
  0x0301, 0x0300, 0x0308, 0x0316, 0x0338, 0x0327, 0x093C, 0x094D, //
  0x09BC, 0x09CD, 0x064B, 0x064E, 0x0651, 0x0652, 0x0653, 0x0654,
  0x0670, 0x05B0, 0x0E38, 0x0F71, 0x0F72, 0x17D2, 0x302A, 0x1D165,
  0x09BE, 0x0B3E, 0x0DCF, 0x0DCA, 0x1161, 0x20E3, 0x1F3FB,
];

const _spaces = [0x20, 0x3164, 0x0A];

int _pick(Random rnd, List<int> pool) => pool[rnd.nextInt(pool.length)];

String _randomName(Random rnd, int length) {
  final out = <int>[];
  for (var i = 0; i < length; i++) {
    final k = rnd.nextInt(20);
    out.add(
      k < 5
          ? _pick(rnd, _joiners)
          : k < 7
          ? _pick(rnd, _dropped)
          : k < 12
          ? _pick(rnd, _bases)
          : k < 19
          ? _pick(rnd, _accents)
          : _pick(rnd, _spaces),
    );
  }
  return String.fromCharCodes(out);
}

/// A base, then units of a joiner and accents, then a base: the shape of
/// the names that took one pass per joiner.
String _cascade(Random rnd, int units) {
  final b = StringBuffer(String.fromCharCode(_pick(rnd, _bases)));
  while (b.length < units - 2) {
    b.writeCharCode(_pick(rnd, _accents));
    if (rnd.nextBool()) b.writeCharCode(_pick(rnd, _accents));
    b.writeCharCode(rnd.nextInt(8) == 0 ? 0x200B : _pick(rnd, _joiners));
  }
  b.writeCharCode(_pick(rnd, _bases));
  return b.toString();
}

int _work(void Function() f) {
  final before = NameText.unormUnits;
  f();
  return NameText.unormUnits - before;
}

void main() {
  test('every character NFC composes is of the same joiner kind as each '
      'base it is made of, and is a starter', () {
    var composites = 0;
    for (var c = 0x80; c <= 0x10FFFF; c++) {
      if (c >= 0xD800 && c <= 0xDFFF) continue;
      final s = String.fromCharCode(c);
      if (unorm.nfc(s) != s) continue;
      final d = unorm.nfd(s).runes.toList();
      if (d.length < 2) continue;
      composites++;
      expect(NameText.isNonStarter(c), isFalse, reason: _hex(s));
      expect(_ccc(d.first), 0, reason: _hex(s));
      for (final r in d) {
        if (_ccc(r) != 0) continue;
        expect(
          NameText.joinKind(r),
          NameText.joinKind(c),
          reason: '${_hex(s)} from ${_hex(String.fromCharCode(r))}',
        );
      }
    }
    expect(composites, greaterThan(12000)); // Hangul and the rest
  });

  test('the invisibles a name keeps are starters, and isNonStarter is the '
      'canonical combining class', () {
    for (final r in [
      0x200C,
      0x200D,
      for (var v = 0xFE00; v <= 0xFE0F; v++) v,
      for (var t = 0xE0020; t <= 0xE007F; t++) t,
    ]) {
      expect(
        NameText.isNonStarter(r),
        isFalse,
        reason: _hex(String.fromCharCode(r)),
      );
    }
    final rnd = Random(1701);
    for (var i = 0; i < 20000; i++) {
      var r = rnd.nextInt(0x30000);
      if (r >= 0xD800 && r <= 0xDFFF) r = 0x0300 + (r & 0xFF);
      expect(NameText.isNonStarter(r), _ccc(r) != 0, reason: '$r');
    }
  });

  test('the cascades QA found take one pass and keep the joiner between '
      'two bases of a joining script', () {
    for (final (h, u, t) in const [
      ('क́', '‍़', 'क'),
      ('ب́', '‌ً', 'ب'),
      ('ب̖', '‍ّ', 'ب'),
      ('क́', '‍्', 'ष'),
    ]) {
      final s = h + u * 50 + t;
      final n = NameText.normalize(s);
      expect(NameText.normalizeOnePass(s), n, reason: _hex(s));
      expect(NameText.normalizeReference(s), n, reason: _hex(s));
      expect(NameText.normalize(n), n, reason: _hex(s));
      // The first joiner stands between two letters of its script and
      // stays; each one after it has that joiner as its base (the accents
      // between are no base) and goes, as two joiners in a row do.
      final joiners = n.runes.where((r) => r == 0x200C || r == 0x200D);
      expect(joiners.length, 1, reason: _hex(s));
      expect(n.startsWith(h + u[0]), isTrue, reason: _hex(s));
    }
    // An accent before a joiner no longer decides it: the half form keeps
    // its ZWJ after an acute, and an emoji ZWJ sequence its ZWJ after an
    // accent.
    expect(NameText.normalize('क्́‍ष'), 'क्́‍ष');
    expect(NameText.normalize('\u{1F469}́‍\u{1F4BB}'), '\u{1F469}́‍\u{1F4BB}');
    // A joiner with no base after it goes, accents after it or not, and
    // the accents around it then sort as NFC sorts them.
    expect(NameText.normalize('क́‍़'), 'क़́');
    expect(NameText.normalize('क́‍़ a'), 'क़́ a');
    // An arrow and the slash that composes with it are both emoji bases.
    expect(NameText.normalize('↔​̸‍\u{1F600}'), '↮‍\u{1F600}');
  });

  test('seeded random names over bases, accents of every class, joiners '
      'and left-out invisibles: one pass gives the normal form', () {
    final rnd = Random(1717);
    for (var i = 0; i < 60000; i++) {
      final s = _randomName(rnd, 1 + rnd.nextInt(14));
      final n = NameText.normalize(s);
      final why = _hex(s);
      expect(NameText.normalizeOnePass(s), n, reason: 'one pass: $why');
      expect(NameText.normalizeReference(s), n, reason: 'reference: $why');
      expect(NameText.normalize(n), n, reason: 'idempotent: $why');
      expect(NameText.normalizeOnePass(n), n, reason: 'pass of n: $why');
    }
  });

  test('seeded random cascades of every length up to a peer name: one pass, '
      'and work linear in the length', () {
    final rnd = Random(1703);
    for (var i = 0; i < 400; i++) {
      final units = 8 + rnd.nextInt(kMaxPeerNameUnits - 8);
      final s = _cascade(rnd, units);
      final why = '${_hex(s.substring(0, 8))}... (${s.length} units)';
      late String n;
      // NFKC and NFC once each over the name, and NFC never again.
      final w = _work(() => n = NameText.normalize(s));
      expect(w, lessThanOrEqualTo(2 * s.length), reason: why);
      expect(NameText.normalizeOnePass(s), n, reason: why);
      expect(NameText.normalize(n), n, reason: why);
      expect(
        _work(() => cleanPeerName(s)),
        lessThanOrEqualTo(10 * kMaxPeerNameUnits),
        reason: why,
      );
    }
  });

  test('display of cascades within the remote limits stays within the work '
      'bound (10 x limit x unitsPerChar), and fit matches the reference', () {
    final rnd = Random(1719);
    for (final (limit, units) in [
      (NameText.maxLength, 160),
      (NameText.maxGroupLength, 240),
    ]) {
      final bound = 10 * limit * NameText.unitsPerChar;
      for (var i = 0; i < 300; i++) {
        final s = _cascade(rnd, units - rnd.nextInt(units ~/ 2));
        final why = '${_hex(s.substring(0, 8))}... (${s.length} units)';
        expect(
          _work(() => NameText.display(s, limit)),
          lessThanOrEqualTo(bound),
          reason: why,
        );
        expect(
          NameText.fit(s, limit),
          NameText.fitReference(s, limit),
          reason: why,
        );
      }
    }
  });

  test('an invite link whose names are cascades of the peer limit parses in '
      'linear work', () {
    final rnd = Random(1729);
    for (var i = 0; i < 20; i++) {
      final s = _cascade(rnd, kMaxPeerNameUnits);
      final link =
          'settleup://join?v=1&g=g1&k=${'A' * 43}&c=INR'
          '&n=${Uri.encodeQueryComponent(s)}'
          '&f=${Uri.encodeQueryComponent(s)}';
      expect(
        _work(() => InviteLink.tryParse(link)),
        lessThanOrEqualTo(20 * kMaxPeerNameUnits),
      );
    }
  });
}
