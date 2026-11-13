// QA DATA round 19: reverification probes for DATA-R18-01 (per-code-point
// name tables outside the BMP) and DATA-R18-02 (perf bounds under load).
//
// The cold relaunch bound opens each log in a fresh isolate, so each of its
// opens is the cold open a relaunch makes whatever this process has shown
// before (the R18 repro measures the open after it has shown the names
// once, with the tables already warm), and it can take the fastest of
// several, so a burst of host load over one does not decide it
// (DATA-R32-02).
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/normal_form.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../data/name_replay_perf_test.dart'
    show
        SampleRun,
        alternateSamples,
        coldSample,
        cpuMicros,
        kOpenRuns,
        markCost;
import 'r15_regression_test.dart' show logPhone;
import 'r17_regression_test.dart' show memberCreates;
import 'r18_regression_test.dart' show astralName, fewAstralName;

/// A name of [piece] repeated after a number, at most 160 units.
String Function(int) pieceName(String piece) => (i) {
  final b = StringBuffer('$i');
  while (b.length + piece.length <= 160) {
    b.write(piece);
  }
  return b.toString();
};

Future<({int openMs, int rss, int shown})> open(
  int n,
  String Function(int) name,
) async {
  final before = ProcessInfo.currentRss;
  final r = await logPhone(memberCreates(n, name), base: false);
  final rss = ProcessInfo.currentRss - before;
  final shown = r.phone
      .group('group-1')
      .members
      .keys
      .where((m) => m.startsWith('r17-m'))
      .length;
  await r.phone.close();
  r.phone.dir.deleteSync(recursive: true);
  return (openMs: r.openMs, rss: rss, shown: shown);
}

/// One open of [open] in a fresh isolate ([coldSample]): the cold open a
/// relaunch makes, for every table an isolate fills on first use, whatever
/// this isolate has shown. [tables] is what those tables held as the
/// sample began, the same for every fresh isolate.
typedef ColdOpen = ({int openMs, int rss, int shown, (int, int) tables});

Future<ColdOpen> coldOpen(int n, String Function(int) name) =>
    coldSample(() async {
      final tables = (NormalForm.astralEntries, NameText.astralEntries);
      final o = await open(n, name);
      return (openMs: o.openMs, rss: o.rss, shown: o.shown, tables: tables);
    });

/// How many members the cold relaunch bound opens: 13,107 names of 80 code
/// points that between them cover every code point outside the BMP.
const int kColdRelaunchMembers = 0x100000 ~/ 80;

/// The cold opens of the cold relaunch bound: [kColdRelaunchMembers]
/// members with names over 256 astral code points (the control) and with
/// names over every astral code point, each opened [runs] times by
/// [alternateSamples], each open in a fresh isolate so each is as cold as
/// the first after a relaunch (DATA-R32-02). [around] wraps each open (for
/// a probe that loads the host over some of them).
Future<({List<ColdOpen> control, List<ColdOpen> astral})> coldRelaunches({
  int runs = kOpenRuns,
  SampleRun<ColdOpen>? around,
}) async {
  const n = kColdRelaunchMembers;
  final r = await alternateSamples(
    () => coldOpen(n, fewAstralName),
    () => coldOpen(n, astralName),
    runs: runs,
    around: around,
  );
  return (control: r.ordinary, astral: r.heavy);
}

/// The bound on [coldRelaunches]: the fastest cold open of the astral
/// names within the charter (< 2 s) and about as fast as the fastest of
/// the control (twice it, and 300 ms), on the wall clock; and the memory
/// the astral names keep about what the control's do.
void expectColdRelaunchWithinBudget(
  ({List<ColdOpen> control, List<ColdOpen> astral}) r,
) {
  int fastest(List<ColdOpen> s) => s.map((o) => o.openMs).reduce(min);
  int most(List<ColdOpen> s) => s.map((o) => o.rss).reduce(max);
  final c = fastest(r.control), a = fastest(r.astral);
  final why = 'control ${r.control}; astral ${r.astral}';
  // Every open was cold: each began with the tables of a fresh isolate,
  // although the astral opens before it filled them.
  final cold = r.control.first.tables;
  for (final o in [...r.control, ...r.astral]) {
    expect(o.tables, cold, reason: why);
  }
  for (final o in r.astral) {
    expect(o.shown, kColdRelaunchMembers, reason: why);
  }
  expect(most(r.astral) - most(r.control), lessThan(32 << 20), reason: why);
  expect(a, lessThan(2000), reason: why);
  expect(a, lessThan(2 * c + 300), reason: why);
}

/// This thread's run time as the kernel's scheduler statistics count it,
/// or null where they are not readable.
int? _schedstatMicros() {
  try {
    final stat = File('/proc/thread-self/schedstat').readAsStringSync();
    return int.parse(stat.split(' ').first) ~/ 1000;
  } on Object {
    return null;
  }
}

void main() {
  test('cold relaunch: 13,107 members whose names cover every code point '
      'outside the BMP open about as fast, and keep about as much memory, as '
      'names of the same length and kind over 256 code points', () async {
    final r = await coldRelaunches();
    // ignore: avoid_print
    print(
      '[r19] 13k astral names, cold opens in fresh isolates: control '
      '${r.control}; astral ${r.astral}; NormalForm astral entries '
      '${NormalForm.astralEntries}, NameText ${NameText.astralEntries}',
    );
    expectColdRelaunchWithinBudget(r);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a 20k-op log of member names that cover every astral code point (and '
      'half again) opens in < 2 s', () async {
    // The faster of two opens, so a burst of load on the shared host the
    // -j 2 suite runs on does not decide it (DATA-R18-02).
    final a = await open(20000, (i) => astralName(i + 7));
    final b = await open(20000, (i) => astralName(i + 7));
    // ignore: avoid_print
    print('[r19] 20k astral names: $a, $b');
    expect(a.shown, 20000);
    expect(min(a.openMs, b.openMs), lessThan(2000));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the tables hold no more after every astral code point is shown in '
      'every position a name can put it (alone, after a letter, after a '
      'space, before an invisible, as a head that is cut)', () {
    final before = (NormalForm.astralEntries, NameText.astralEntries);
    for (var r = 0x10000; r <= 0x10FFFF; r++) {
      final c = String.fromCharCode(r);
      NameText.display(c);
      NameText.display('a$c');
      NameText.display(' $c ');
      NameText.display('$c​$c');
      NameText.key('x$c­');
    }
    // A cut head: 70 drawn characters, then astral code points.
    for (var r = 0x10000; r <= 0x10FFFF; r += 40) {
      final b = StringBuffer('a' * 36);
      for (var k = 0; k < 40; k++) {
        b.writeCharCode(r + k <= 0x10FFFF ? r + k : 0x10000);
      }
      NameText.fit(b.toString());
    }
    var decompose = 0;
    for (var c = 0x10000; c <= 0x10FFFF; c++) {
      if (NormalForm.decomposes(c)) decompose++;
    }
    // ignore: avoid_print
    print(
      '[r19] astral entries before $before, after '
      '(${NormalForm.astralEntries}, ${NameText.astralEntries}); '
      '$decompose decompose',
    );
    // NormalForm.astralEntries also counts the decompositions of the BMP
    // characters met so far: a few may be added here, bounded by the BMP
    // table; none for the astral code points.
    expect(NormalForm.astralEntries - before.$1, lessThan(64));
    expect(NameText.astralEntries, lessThanOrEqualTo(2 * decompose));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('names of astral characters that draw nothing, astral marks after '
      'spaces and astral compatibility characters cost what the budget '
      'allows (CPU time, 4k members < 300 ms)', () async {
    final pieces = {
      'tag characters (draw nothing)': '\u{E0041}\u{E0062}',
      'astral marks after spaces': '\u{1D165} ',
      'astral marks split by tags': '\u{1D16E}\u{E0020}',
      'variation selectors supplement': 'a\u{E0100}\u{E01EF}',
      'math alphanumerics (NFKC)': '\u{1D400}\u{1D7CE}',
      'CJK compatibility (NFC)': '\u{2F800}\u{2FA1D}',
      'musical symbols that decompose': '\u{1D15E}\u{1D1BB}',
      'shorthand format controls': '\u{1BCA0}\u{1BCA3}',
    };
    final rows = <String>[];
    for (final e in pieces.entries) {
      final r = await markCost(e.value);
      rows.add('${e.key}: $r');
      expect(r.cpuMs, lessThan(300), reason: e.key);
    }
    // ignore: avoid_print
    print('[r19] 4k members by astral class: $rows');
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('cpuMicros measures this thread\'s CPU time, not the wall clock', () {
    final wall = Stopwatch()..start();
    final t = cpuMicros();
    sleep(const Duration(milliseconds: 300));
    final idle = cpuMicros() - t;
    var x = 0;
    final sched0 = _schedstatMicros();
    final t2 = cpuMicros();
    final spin = Stopwatch()..start();
    while (spin.elapsedMilliseconds < 300) {
      x = (x * 31 + 7) & 0xFFFFFF;
    }
    final busy = cpuMicros() - t2;
    final sched1 = _schedstatMicros();
    // ignore: avoid_print
    print(
      '[r19] cpuMicros: idle 300 ms -> $idle us, busy 300 ms -> $busy us '
      '(wall ${wall.elapsedMilliseconds} ms, $x)',
    );
    expect(idle, lessThan(50000));
    // 300 ms of spinning is at least 100 ms of CPU unless the host starves
    // this thread (a load average near 8 on 4 CPUs gave it 77 ms in round
    // 24); then the kernel's own count for the thread must agree instead.
    if (busy <= 100000 && sched1 != null && sched0 != null) {
      expect(
        (busy - (sched1 - sched0)).abs(),
        lessThan(5000 + busy ~/ 20),
        reason:
            'starved: cpuMicros $busy us, schedstat '
            '${sched1 - sched0} us',
      );
    } else {
      expect(busy, greaterThan(100000));
    }
  });

  differentialProbe();
}

/// Seeded names from a pool wider than name_text_tables_test.dart's: it
/// adds characters that draw nothing (in and outside the BMP), joiners,
/// lone surrogates, Hangul jamo, emoji sequences and astral marks and
/// compatibility characters, around the passes DATA-R18-01/02 changed.
void differentialProbe() {
  test('property: wide seeded names normalise, fit and key as the reference '
      'does, and NormalForm matches unorm_dart on them', () {
    const pool = [
      'a', 'Z', '7', 'é', '一', '\u{1D400}', '\u{10000}', 'ﷺ',
      'ཷ', '̈́', '́', '\u{1D165}', '\u{1D16E}', '़', //
      'ﾞ', ' ', '  ', '\t', ' ', '　', 'ㅤ', 'ᅟ',
      'ᅠ', '​', '­', '‍', '‌', '﻿', '⁠',
      '\u{E0041}', '\u{E0020}', '\u{E0100}', '\u{1BCA0}', '\u{1D173}',
      '\uD800', '\uDC00', 'ᄀ', 'ᅡ', 'ᆨ', '가', '\u{1F468}',
      '\u{1F3FB}', '\u{1F1EE}', '\u{1F1F3}', '️', '\u{2F800}',
      '\u{1D15E}', '\u{11099}', '\u{110BA}', '\u{1133E}', '\u{11347}',
      '\u{10FFFF}', '\u{1FFFE}', '\u{50000}',
    ];
    final rnd = Random(1901);
    var checked = 0;
    for (var k = 0; k < 4000; k++) {
      final b = StringBuffer();
      final n = 1 + rnd.nextInt(120);
      while (b.length < n) {
        final piece = pool[rnd.nextInt(pool.length)];
        b.write(rnd.nextInt(6) == 0 ? piece * (1 + rnd.nextInt(30)) : piece);
      }
      final s = b.toString();
      final why = s.codeUnits.map((u) => u.toRadixString(16)).join(' ');
      expect(
        NameText.normalize(s),
        NameText.normalizeReference(s),
        reason: why,
      );
      expect(NameText.normalizeOnePass(s), NameText.normalize(s), reason: why);
      final f = NameText.fit(s);
      expect(f, NameText.fitReference(s), reason: why);
      expect(NameText.fit(f), f, reason: why);
      expect(NameText.fits(f, NameText.maxLength), isTrue, reason: why);
      final g = NameText.fit(s, NameText.maxGroupLength);
      expect(g, NameText.fitReference(s, NameText.maxGroupLength), reason: why);
      // unorm_dart is not defined on lone surrogates.
      if (s.runes.every((r) => r < 0xD800 || r > 0xDFFF)) {
        expect(NormalForm.nfkc(s), unorm.nfkc(s), reason: 'NFKC $why');
        expect(NormalForm.nfc(s), unorm.nfc(s), reason: 'NFC $why');
        checked++;
      }
    }
    expect(checked, greaterThan(1000));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
