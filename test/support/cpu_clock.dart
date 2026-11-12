// A clock for the micro-benchmarks of the test suite: the CPU time the
// calling thread has run, at a resolution the timed windows can rely on.
//
// The wall clock counts whatever else the host runs (the other test file
// `flutter test -j 2` runs beside this one, other work on a shared host),
// so a bound on it fails under load. The kernel's scheduler statistics
// (/proc/thread-self/schedstat) count only this thread, but for a running
// thread they move only when the scheduler accounts it: in steps of 0.3 to
// 3.8 ms on the shared host, so a window of about 1 ms reads 0 or a step
// (DATA-R21-01). clock_gettime(CLOCK_THREAD_CPUTIME_ID) asks the kernel to
// account the running thread first, so it resolves to the nanosecond; and
// [cpuMicrosPer] times windows of at least [kMinCpuWindowMicros] whatever
// clock is in use, so even a stepped one resolves them.
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

/// CLOCK_THREAD_CPUTIME_ID on Linux and Android.
const int _clockThreadCpuTimeId = 3;

typedef _ClockGettimeC = Int32 Function(Int32, Pointer<Int64>);
typedef _ClockGettime = int Function(int, Pointer<Int64>);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);

/// clock_gettime from libc, and a timespec for it (two 64-bit words,
/// allocated once and kept for the life of the isolate); null where the
/// process does not export it.
final ({_ClockGettime call, Pointer<Int64> ts})? _threadClock = () {
  if (!(Platform.isLinux || Platform.isAndroid)) return null;
  try {
    final libc = DynamicLibrary.process();
    final call = libc.lookupFunction<_ClockGettimeC, _ClockGettime>(
      'clock_gettime',
      isLeaf: true,
    );
    final malloc = libc.lookupFunction<_MallocC, _Malloc>('malloc');
    final ts = malloc(16).cast<Int64>();
    if (ts == nullptr || call(_clockThreadCpuTimeId, ts) != 0) return null;
    return (call: call, ts: ts);
  } on Object {
    return null;
  }
}();

/// Which clock [threadCpuMicros] reads: `thread-cputime`, `schedstat` or
/// `wall`.
final String cpuClockSource = _threadClock != null
    ? 'thread-cputime'
    : _schedstatMicros() != null
    ? 'schedstat'
    : 'wall';

int? _schedstatMicros() {
  try {
    final stat = File('/proc/thread-self/schedstat').readAsStringSync();
    return int.parse(stat.split(' ').first) ~/ 1000;
  } on Object {
    return null;
  }
}

/// The CPU time this thread has run, in microseconds: what synchronous work
/// costs, whatever else the host runs. The kernel's scheduler statistics
/// where clock_gettime is not available, and the wall clock where the
/// kernel tells neither.
int threadCpuMicros() {
  final c = _threadClock;
  if (c != null && c.call(_clockThreadCpuTimeId, c.ts) == 0) {
    return c.ts[0] * 1000000 + c.ts[1] ~/ 1000;
  }
  return _schedstatMicros() ?? DateTime.now().microsecondsSinceEpoch;
}

/// The least CPU time one timed window of [cpuMicrosPer] runs for, in us:
/// over ten times the coarsest step of the scheduler statistics seen on the
/// shared host, so a window resolves to within 10% on any clock in use.
const int kMinCpuWindowMicros = 40000;

/// The CPU time one call of [body] takes, in us: [warmUp] calls first so
/// the code is optimised, then the fastest of [runs] windows, each of at
/// least [minCalls] calls and [kMinCpuWindowMicros] of CPU time. [body]
/// gets the index of the call, so it can vary its input. The clock is read
/// between batches of calls only, so reading it costs nothing measurable.
double cpuMicrosPer(
  void Function(int i) body, {
  int warmUp = 1000,
  int runs = 3,
  int minCalls = 300,
}) {
  for (var i = 0; i < warmUp; i++) {
    body(i);
  }
  var best = double.infinity;
  for (var k = 0; k < runs; k++) {
    var calls = 0, batch = 16;
    final start = threadCpuMicros();
    var spent = 0;
    while (calls < minCalls || spent < kMinCpuWindowMicros) {
      for (var j = 0; j < batch; j++) {
        body(calls + j);
      }
      calls += batch;
      final before = spent;
      spent = threadCpuMicros() - start;
      // Read the clock about every 1-2 ms of work whatever a call costs.
      if (spent - before < 1000) batch = min(batch * 2, 1 << 16);
    }
    best = min(best, spent / calls);
  }
  return best;
}
