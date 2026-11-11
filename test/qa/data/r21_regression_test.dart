// QA DATA round 21: failing repros for findings of the final sweep.
//
// Tests named "QA <id>" with `skip:` are failing repros for open findings;
// they pass once the finding is fixed.
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

import 'r17_regression_test.dart'
    show R17Cost, displayMicros, expectR17, markName, measureR17;

void main() {
  test(
    'QA DATA-R21-01: the DATA-R15-01 reverification in '
    'r17_regression_test.dart fails under the load of the full suite '
    '(-j 2): one wall-clock open of 4k mark-heavy members against an '
    'absolute 400 ms bound, while ordinary names take as long',
    () async {
      // Four busy isolates stand in for the other test process the full
      // suite runs beside this one with -j 2, and the other work on the
      // shared 4-CPU host (the DATA-R18-02 method).
      final stops = <Isolate>[
        for (var k = 0; k < 4; k++)
          await Isolate.spawn((_) {
            var x = 0;
            while (true) {
              x = (x * 31 + 7) & 0xFFFFFF;
            }
          }, null),
      ];
      final rows = <String>[];
      final runs = <R17Cost>[];
      try {
        for (var k = 0; k < 3; k++) {
          // Exactly what r17_regression_test.dart measures and asserts.
          final r = await measureR17();
          rows.add(
            'ordinary ${r.open.ordinaryMs} ms, marks ${r.open.openMs} ms, '
            'names ${r.open.cpuMs} ms CPU',
          );
          runs.add(r);
        }
      } finally {
        for (final i in stops) {
          i.kill(priority: Isolate.immediate);
        }
      }
      // ignore: avoid_print
      print('[r21] under load, 4k members, the R17 open: $rows');
      // The R17 test takes one such measurement and asserts this; the full
      // suite must stay green on the shared host it runs on.
      runs.forEach(expectR17);
    },
    // Reopened in round 23: fails 2 of 5 runs alone on the host (the
    // display bound, r17_regression_test.dart:119-120), see below.
    skip:
        'QA DATA-R21-01: The DATA-R15-01 reverification in '
        'r17_regression_test.dart fails under the full -j 2 suite load',
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'QA DATA-R21-01 (round 23): the display bound of the DATA-R15-01 '
    'reverification is held in CPU time over ~1 ms windows, which the '
    "kernel's schedstat clock does not resolve: an ordinary name reads "
    '0 us, so 5 x ordinary + 50 is an absolute 50 us',
    () {
      // r17_regression_test.dart displayMicros: the fastest of three runs of
      // 300 displays, each timed with cpuMicros (/proc/thread-self/schedstat,
      // which advances in steps of 0.3-3.8 ms on this host). 300 ordinary
      // displays take ~1.2 ms, so the fastest window usually sees no step.
      final ordinary = [
        for (var k = 0; k < 10; k++)
          displayMicros((i) => 'Person ${'x' * 150}$i', 40),
      ];
      final marks = displayMicros(markName, 40);
      final group = displayMicros(
        (i) => 'x${'\u0F77' * 238}${i % 10}',
        NameText.maxGroupLength,
      );
      // ignore: avoid_print
      print(
        '[r23] display CPU us: ordinary $ordinary, marks $marks, '
        'group $group',
      );
      // Each measurement must resolve the cost it measures, or the relative
      // bound is no bound: group names take ~26 us quiet and 48-52 us beside
      // four busy isolates, against 5 x 0 + 50.
      expect(ordinary, everyElement(greaterThan(0)));
    },
    skip:
        'QA DATA-R21-01: The DATA-R15-01 reverification in '
        'r17_regression_test.dart fails under the full -j 2 suite load',
  );
}
