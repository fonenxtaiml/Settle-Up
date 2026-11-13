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
// This repro applies that test's measurement and bounds (since the fix, the
// shared coldRelaunches and expectColdRelaunchWithinBudget: each open in a
// fresh isolate, so each is cold, alternately, the fastest of each taken)
// with the same burst of load the DATA-R32-02 repro uses (six busy
// isolates) over one cold astral open only. Its opens are cold whatever
// this process showed before, so it need not be alone in its file.
import 'package:flutter_test/flutter_test.dart';

import 'r19_probe_test.dart'
    show ColdOpen, coldRelaunches, expectColdRelaunchWithinBudget;
import 'r32_perf_load_test.dart' show underLoad;

void main() {
  test('QA DATA-R32-02 repro (r33): the cold relaunch bound of 13,107 astral '
      'names holds when host load comes and goes over its one wall-clock '
      'sample', () async {
    ColdOpen? loaded;
    final r = await coldRelaunches(
      around: (run, astral, open) async {
        if (!astral || run != 0) return open();
        final o = await underLoad(open);
        loaded = o;
        return o;
      },
    );
    // ignore: avoid_print
    print(
      '[r33] 13k astral names, load over one cold astral open only: '
      'control ${r.control}; astral ${r.astral} (the loaded open '
      '${loaded?.openMs} ms)',
    );
    expectColdRelaunchWithinBudget(r);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
