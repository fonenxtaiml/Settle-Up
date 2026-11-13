// QA DATA round 32: the 5,000 member creates bound in
// test/data/name_replay_perf_test.dart ('20k ops + 5,000 members created
// with distinct 159 x U+FDFA names open within the budget of 0.1 ms an op')
// failed the full -j 2 suite of this round (heavyMs - ordinary 1282 ms, bound
// 1007 ms) and passes alone (about 200 ms against 1000). It takes one
// wall-clock sample of each open and scales the bound by the ordinary one
// only, so a burst of host load over the heavy open alone fails it. The
// rename test beside it takes the faster of two alternating runs for this
// reason (DATA-R18-02).
//
// The repro applies that test's measurement and bound (since the fix, the
// shared fasterOpens and expectCreatesWithinBudget) with a burst of load
// (busy isolates) over one heavy open only, which is what a shared host
// does to one test file of two under -j 2.
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import '../../data/name_replay_perf_test.dart'
    show createsLogs, expectCreatesWithinBudget, fasterOpens;

/// Runs [open] while six isolates keep the host's CPUs busy.
Future<T> underLoad<T>(Future<T> Function() open) async {
  final busy = <Isolate>[
    for (var k = 0; k < 6; k++)
      await Isolate.spawn((_) {
        var x = 0;
        while (true) {
          x = (x * 31 + 7) & 0xFFFFFF;
        }
      }, null),
  ];
  try {
    return await open();
  } finally {
    for (final i in busy) {
      i.kill(priority: Isolate.immediate);
    }
  }
}

void main() {
  test('QA DATA-R32-02 repro: the 5,000 member creates open bound holds when '
      'host load comes and goes between its two wall-clock samples', () async {
    final logs = createsLogs();
    var loaded = 0;
    final r = await fasterOpens(
      logs.ordinary,
      logs.heavy,
      around: (run, heavy, open) async {
        if (!heavy || run != 0) return open();
        return loaded = await underLoad(open);
      },
    );
    // ignore: avoid_print
    print(
      '[r32] 5k creates, load over one heavy open only: ordinary '
      '${r.ordinaryMs} ms, heavy ${r.heavyMs} ms (the loaded open '
      '$loaded ms)',
    );
    expectCreatesWithinBudget(r);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
