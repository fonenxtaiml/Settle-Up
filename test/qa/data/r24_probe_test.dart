// QA DATA round 24: reverification probes for DATA-R21-01.
//
// The micro-benchmarks of the DATA-R15-01 reverification now time windows
// of at least 40 ms on clock_gettime(CLOCK_THREAD_CPUTIME_ID), read through
// FFI (test/support/cpu_clock.dart). These probes hold that clock against
// an independent oracle, the kernel's scheduler statistics for the same
// thread, over windows long enough for the stepped statistics to resolve.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/cpu_clock.dart';

int? schedstatMicros() {
  try {
    final stat = File('/proc/thread-self/schedstat').readAsStringSync();
    return int.parse(stat.split(' ').first) ~/ 1000;
  } on Object {
    return null;
  }
}

int spin(int n) {
  var x = 1;
  for (var i = 0; i < n; i++) {
    x = (x * 31 + i) & 0xFFFFFF;
  }
  return x;
}

void main() {
  final hasSchedstat = schedstatMicros() != null;

  test('over 250 ms of work the thread CPU clock reads what the kernel '
      'scheduler statistics read for the same thread', () {
    final s0 = schedstatMicros()!, c0 = threadCpuMicros();
    while (threadCpuMicros() - c0 < 250000) {
      spin(20000);
    }
    final c = threadCpuMicros() - c0, s = schedstatMicros()! - s0;
    // ignore: avoid_print
    print('[r24] 250 ms of work: thread clock $c us, schedstat $s us');
    // The statistics step by up to ~4 ms; allow that and 5%.
    expect((c - s).abs(), lessThan(5000 + c ~/ 20), reason: '$c vs $s');
  }, skip: hasSchedstat ? false : 'no scheduler statistics on this host');

  test('over a sleep both clocks stay near zero', () {
    final s0 = schedstatMicros()!, c0 = threadCpuMicros();
    sleep(const Duration(milliseconds: 200));
    final c = threadCpuMicros() - c0, s = schedstatMicros()! - s0;
    expect(c, lessThan(20000));
    expect(s, lessThan(20000));
  }, skip: hasSchedstat ? false : 'no scheduler statistics on this host');
}
