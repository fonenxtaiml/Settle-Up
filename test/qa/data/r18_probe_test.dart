// QA DATA-R18: probes around the DATA-R15-01 fix (NormalForm, a linear-time
// normaliser, and the shortcuts in NameText). Differential checks against
// unorm_dart and the reference forms, the cost of showing names of every
// class a peer can send within the remote limits, and replay at scale.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/normal_form.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../support/cpu_clock.dart' show cpuMicrosPer;

import 'r15_regression_test.dart' show logPhone;
import 'r17_regression_test.dart' show memberCreates;

String _hex(String s) => s.runes
    .map((r) => r.toRadixString(16).toUpperCase().padLeft(4, '0'))
    .join(' ');

/// Code points that decomposition, ordering or composition treat
/// specially, found from unorm_dart itself (not a hand-picked pool).
List<int> _special() {
  final out = <int>[];
  for (var r = 0xA0; r <= 0x2FFFF; r++) {
    if (r == 0x3400) r = 0xA000;
    if (r == 0xD800) r = 0xE000;
    final s = String.fromCharCode(r);
    if (unorm.nfkd(s) != s ||
        NormalForm.combiningClass(r) != 0 ||
        NormalForm.joinsPrevious(r)) {
      out.add(r);
    }
  }
  return out;
}

String _name(Random rnd, List<int> pool, int n) {
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    final k = rnd.nextInt(10);
    if (k < 6) {
      b.writeCharCode(pool[rnd.nextInt(pool.length)]);
    } else if (k < 7) {
      b.writeCharCode(0x61 + rnd.nextInt(26));
    } else if (k < 8) {
      b.writeCharCode(
        const [
          0x20,
          0x200D,
          0x200C,
          0xAD,
          0x200B,
          0xFE0F,
          0x3000,
          0x2060,
          0x1F469,
          0x0628,
          0x0915,
          0x094D,
          0x1100,
          0x1161,
          0x11A8,
          0xAC00,
          0x3164,
        ][rnd.nextInt(17)],
      );
    } else {
      // A random code point anywhere (lone surrogates included).
      b.writeCharCode(rnd.nextInt(0x30000));
    }
  }
  return b.toString();
}

/// The CPU time one display of [name]s takes, in us: the fastest of two
/// windows of at least 40 ms after a warm-up, so the load of the full
/// suite does not decide (DATA-R21-01).
double _micros(String Function(int) name, int limit) => cpuMicrosPer(
  (i) => NameText.display(name(i), limit),
  warmUp: 1500,
  runs: 2,
  minCalls: 400,
);

/// A name of [units] code units: a number, then [piece] repeated.
String Function(int) _of(String piece, [int units = 160, String lead = '']) =>
    (i) {
      final b = StringBuffer('$lead$i');
      while (b.length + piece.length <= units) {
        b.write(piece);
      }
      return b.toString();
    };

void main() {
  late List<int> special;
  setUpAll(() => special = _special());

  test('NormalForm gives the forms unorm_dart gives for random texts drawn '
      'from every special code point, random code points and joiners', () {
    final rnd = Random(18018);
    final bad = <String>[];
    for (var i = 0; i < 40000 && bad.length < 5; i++) {
      final s = _name(rnd, special, 1 + rnd.nextInt(i.isEven ? 8 : 60));
      if (NormalForm.nfkc(s) != unorm.nfkc(s) ||
          NormalForm.nfc(s) != unorm.nfc(s) ||
          NormalForm.nfd(s) != unorm.nfd(s) ||
          NormalForm.nfkd(s) != unorm.nfkd(s)) {
        bad.add(_hex(s));
      }
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('every pair of a character that starts a composition and a '
      'character that may end one has the forms unorm_dart gives', () {
    final firsts = <int>[];
    final seconds = <int>[];
    for (final r in special) {
      if (NormalForm.joinsPrevious(r)) seconds.add(r);
    }
    for (var r = 0x41; r <= 0x2FFFF; r++) {
      if (r == 0x3400) r = 0xA000;
      if (r == 0xD800) r = 0xE000;
      final s = String.fromCharCode(r);
      // r starts some composition when NFC of r + a second differs.
      if (unorm.nfd(s) != s ||
          (r >= 0x1100 && r <= 0x11FF) ||
          (r >= 0xAC00 && r <= 0xD7A3 && (r - 0xAC00) % 28 == 0)) {
        firsts.add(r);
      }
    }
    for (final a in 'AEIOUaeiouCcNnSsZzKkGgHhLlRrWwYy'.runes) {
      firsts.add(a);
    }
    final bad = <String>[];
    final rnd = Random(3);
    for (var i = 0; i < 300000 && bad.length < 5; i++) {
      final a = firsts[rnd.nextInt(firsts.length)];
      final b = seconds[rnd.nextInt(seconds.length)];
      final c = seconds[rnd.nextInt(seconds.length)];
      final s = String.fromCharCodes([a, b, c]);
      if (NormalForm.nfc(s) != unorm.nfc(s) ||
          NormalForm.nfkc(s) != unorm.nfkc(s)) {
        bad.add(_hex(s));
      }
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('normalize and fit with their shortcuts equal the reference forms '
      'for random names of every class', () {
    final rnd = Random(77);
    final bad = <String>[];
    for (var i = 0; i < 6000 && bad.length < 5; i++) {
      final s = _name(rnd, special, 1 + rnd.nextInt(i.isEven ? 12 : 120));
      if (NameText.normalize(s) != NameText.normalizeReference(s)) {
        bad.add('normalize ${_hex(s)}');
      }
      for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
        if (NameText.fit(s, limit) != NameText.fitReference(s, limit)) {
          bad.add('fit $limit ${_hex(s)}');
        }
      }
      final f = NameText.fit(s);
      if (NameText.fit(f) != f) bad.add('fit not idempotent ${_hex(s)}');
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('display cost of names of every class within the remote limits', () {
    final ordinary = _micros((i) => 'Person ${'x' * 150}$i', 40);
    final pieces = <String, String>{
      'U+0344': '̈́',
      'U+0F77': 'ཷ',
      'U+FDFA': 'ﷺ',
      'U+337F': '㍿',
      'Hangul L': 'ᄀ',
      'Hangul V': 'ᅡ',
      'Hangul T': 'ᆨ',
      'Hangul LVT': '각',
      'Hangul LV + T split by soft hyphen': '가­ᆨ',
      'e + soft hyphen + acute': 'e­́',
      'ZWJ': '‍',
      'beh + ZWJ': 'ب‍',
      'emoji ZWJ': '\u{1F469}‍',
      'beh ZWJ ALM': 'ب‍؜',
      'ka virama ZWNJ': 'क्‌',
      'VS16 after x': 'x️',
      'tags': '\u{1F3F4}\u{E0067}\u{E0062}',
      'ideographic spaces': '　',
      'filler + mark': 'ㅤ́',
      'math bold': '\u{1D400}',
      'astral marks': '\u{1D165}\u{1D16E}',
      'ZWSP + U+0F77': '​ཷ',
      'invisible run then marks': '⁠⁠̈́',
      'lone surrogates': '\uD800',
      'Tamil two-part vowel': 'கெ­ா',
    };
    final rows = <String>[];
    var worst = 0.0, worstLabel = '';
    pieces.forEach((label, piece) {
      for (final (limit, units) in [(40, 160), (60, 240)]) {
        final us = _micros(_of(piece, units), limit);
        rows.add('$label/$limit: ${us.toStringAsFixed(1)} us');
        if (us > worst) {
          worst = us;
          worstLabel = '$label/$limit';
        }
      }
    });
    // ignore: avoid_print
    print(
      '[perf] ordinary ${ordinary.toStringAsFixed(1)} us; '
      'worst $worstLabel ${worst.toStringAsFixed(1)} us\n'
      '${rows.join('\n')}',
    );
    // Within the charter's 0.1 ms an op (the worst measured 70-75 us on
    // the host, against about 8 us for an ordinary name).
    expect(worst, lessThan(100));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('20,000 distinct peer members with the costliest names open within '
      'the 2 s budget', () async {
    final names = <String, String Function(int)>{
      'ordinary': (i) => 'Person $i',
      'U+0F77 marks': _of('ཷ'),
      'beh ZWJ ALM': _of('ب‍؜'),
      'marks after spaces': _of('ཷ '),
    };
    final rows = <String>[];
    var worst = 0;
    for (final MapEntry(:key, :value) in names.entries) {
      var best = 1 << 30;
      for (var k = 0; k < 2; k++) {
        final r = await logPhone(memberCreates(20000, value), base: false);
        best = min(best, r.openMs);
        await r.phone.close();
        r.phone.dir.deleteSync(recursive: true);
      }
      rows.add('$key $best ms');
      if (key != 'ordinary') worst = max(worst, best);
    }
    // ignore: avoid_print
    print('[perf] 20k distinct members open: ${rows.join(', ')}');
    expect(worst, lessThan(2000));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
