// The clock of the suite's micro-benchmarks (test/support/cpu_clock.dart)
// resolves the windows it times, counts only this thread's CPU time, and
// [cpuMicrosPer] reads a cost in proportion to the work (DATA-R21-01).
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

import '../support/cpu_clock.dart';

/// Work of [n] units that the compiler cannot drop.
int spin(int n) {
  var x = 1;
  for (var i = 0; i < n; i++) {
    x = (x * 31 + i) & 0xFFFFFF;
  }
  return x;
}

void main() {
  test('on Linux and Android the clock is the thread CPU-time clock', () {
    if (Platform.isLinux || Platform.isAndroid) {
      expect(cpuClockSource, 'thread-cputime');
    }
  });

  test('resolves well under a millisecond of work', () {
    final readings = <int>[];
    for (var k = 0; k < 20; k++) {
      final t = threadCpuMicros();
      spin(20000); // about 20-60 us
      readings.add(threadCpuMicros() - t);
    }
    // The schedstat clock read 0 for most such windows.
    expect(readings, everyElement(greaterThan(0)), reason: '$readings');
    expect(readings, everyElement(lessThan(20000)), reason: '$readings');
  });

  test('never runs backwards and never runs faster than the wall clock', () {
    final sw = Stopwatch()..start();
    final t = threadCpuMicros();
    var last = t;
    for (var k = 0; k < 2000; k++) {
      spin(500);
      final now = threadCpuMicros();
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
    expect(last - t, lessThanOrEqualTo(sw.elapsedMicroseconds + 1000));
  });

  test('does not count time this thread is not running', () {
    final t = threadCpuMicros();
    sleep(const Duration(milliseconds: 300));
    expect(threadCpuMicros() - t, lessThan(30000));
  });

  test('cpuMicrosPer resolves a call of a few us and reads twice the work '
      'as about twice the cost', () {
    final one = cpuMicrosPer((i) => spin(2000));
    final two = cpuMicrosPer((i) => spin(4000));
    // ignore: avoid_print
    print('[cpu-clock] $cpuClockSource: spin 2000 $one us, 4000 $two us');
    expect(one, greaterThan(0));
    expect(two / one, inInclusiveRange(1.4, 2.8));
  });

  test('cpuMicrosPer gives an ordinary name a non-zero display cost beside '
      'four busy isolates, ten times over', () async {
    final busy = <Isolate>[
      for (var k = 0; k < 4; k++)
        await Isolate.spawn((_) {
          var x = 0;
          while (true) {
            x = (x * 31 + 7) & 0xFFFFFF;
          }
        }, null),
    ];
    try {
      final costs = [
        for (var k = 0; k < 10; k++)
          cpuMicrosPer(
            (i) => NameText.display('Person ${'x' * 150}$i', 40),
            warmUp: k == 0 ? 1000 : 0,
          ),
      ];
      // ignore: avoid_print
      print('[cpu-clock] ordinary display under load: $costs us');
      expect(costs, everyElement(greaterThan(0.5)));
      // The fastest of three 40 ms windows: a burst of load does not move it
      // by much.
      final lo = costs.reduce((a, b) => a < b ? a : b);
      expect(costs, everyElement(lessThan(3 * lo)), reason: '$costs');
    } finally {
      for (final i in busy) {
        i.kill(priority: Isolate.immediate);
      }
    }
  });
}
