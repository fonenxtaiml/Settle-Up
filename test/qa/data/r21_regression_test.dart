// QA DATA round 21: failing repros for findings of the final sweep.
//
// Tests named "QA <id>" with `skip:` are failing repros for open findings;
// they pass once the finding is fixed.
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'r17_regression_test.dart' show R17Cost, expectR17, measureR17;

void main() {
  test('QA DATA-R21-01: the DATA-R15-01 reverification in '
      'r17_regression_test.dart fails under the load of the full suite '
      '(-j 2): one wall-clock open of 4k mark-heavy members against an '
      'absolute 400 ms bound, while ordinary names take as long', () async {
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
  }, timeout: const Timeout(Duration(minutes: 6)));
}
