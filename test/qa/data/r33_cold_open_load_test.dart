// QA DATA round 33: the DATA-R32-02 class (a wall-clock perf bound in the
// suite decided by one sample, so a burst of host load over that sample
// alone fails the -j 2 suite) outside name_replay_perf_test.dart.
//
// The fix gave the replay perf tests one way to time the opens they compare
// (fasterOpens: alternating runs, the fastest of each). The cold relaunch
// test in r19_probe_test.dart still compares ONE wall-clock open of 13,107
// astral names against ONE control open (a < 2 * c2 + 300, and a < 2000).
// Its open is cold on purpose (the first in the process to show names
// outside the BMP), so it cannot simply be repeated; a bound on CPU time, or
// a cold open in a fresh isolate per sample, would hold under load.
//
// This repro applies that test's measurement and bounds, as written today,
// with the same burst of load the DATA-R32-02 repro uses (six busy isolates)
// over the cold astral open only. It must stay the only test in its file:
// its open has to be the first in this process to show such names.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'r18_regression_test.dart' show astralName, fewAstralName;
import 'r19_probe_test.dart' show open;
import 'r32_perf_load_test.dart' show underLoad;

void main() {
  test(
    'QA DATA-R32-02 repro (r33): the cold relaunch bound of 13,107 astral '
    'names holds when host load comes and goes over its one wall-clock '
    'sample',
    skip:
        'QA DATA-R32-02: the cold relaunch open bound in r19_probe_test.dart '
        'is still decided by one wall-clock sample',
    () async {
      const n = 0x100000 ~/ 80;
      final c1 = await open(n, fewAstralName);
      final c2 = await open(n, fewAstralName);
      late ({int openMs, int rss, int shown}) a;
      await underLoad(() async {
        a = await open(n, astralName);
        return a.openMs;
      });
      // ignore: avoid_print
      print(
        '[r33] 13k astral names, load over the cold open only: control '
        '${c1.openMs} ms, ${c2.openMs} ms; astral ${a.openMs} ms (bounds '
        '2000 and ${2 * c2.openMs + 300})',
      );
      expect(a.shown, n);
      expect(a.rss - max(c1.rss, c2.rss), lessThan(32 << 20));
      expect(a.openMs, lessThan(2000));
      expect(a.openMs, lessThan(2 * c2.openMs + 300));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
