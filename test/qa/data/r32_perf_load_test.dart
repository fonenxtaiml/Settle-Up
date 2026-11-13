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
// The repro applies that test's measurement and bound, as written today,
// with a burst of load (busy isolates) over the heavy open only, which is
// what a shared host does to one test file of two under -j 2.
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../../data/name_replay_perf_test.dart'
    show creates, heavy, openMs, quietBaseOrdinaryMs;

void main() {
  test(
    'QA DATA-R32-02 repro: the 5,000 member creates open bound holds when '
    'host load comes and goes between its two wall-clock samples',
    skip:
        'QA DATA-R32-02: the 5,000 member creates perf bound fails the '
        'full suite under load: one wall-clock sample per open',
    () async {
      final ordinaryNames = [for (var i = 1; i <= 5000; i++) 'Person $i'];
      final heavyNames = [for (var i = 1; i <= 5000; i++) heavy(i)];
      final ordinary = await openMs(creates(5000, (i) => ordinaryNames[i - 1]));
      final busy = <Isolate>[
        for (var k = 0; k < 6; k++)
          await Isolate.spawn((_) {
            var x = 0;
            while (true) {
              x = (x * 31 + 7) & 0xFFFFFF;
            }
          }, null),
      ];
      final int heavyMs;
      try {
        heavyMs = await openMs(creates(5000, (i) => heavyNames[i - 1]));
      } finally {
        for (final i in busy) {
          i.kill(priority: Isolate.immediate);
        }
      }
      // ignore: avoid_print
      print(
        '[r32] 5k creates, load over the heavy open only: ordinary '
        '$ordinary ms, heavy $heavyMs ms',
      );
      final load = max(1.0, ordinary / quietBaseOrdinaryMs);
      expect(heavyMs - ordinary, lessThan(1000 * load));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
