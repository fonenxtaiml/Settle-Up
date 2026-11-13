// QA DATA round 34: reverification sweep of DATA-R32-02 (perf bounds of the
// release gate suite decided by one wall-clock sample).
//
// The fix takes every open bound over several samples: alternating runs of
// the two logs it compares (alternateSamples, fasterOpens), the fastest of
// a first open and relaunches of the same log (fastestOpenMs, relaunchMs),
// and, for the cold relaunch bound, each open in a fresh isolate so that
// each is cold (coldSample). These probes check the class rather than the
// one input of the repros: bursts of load over a sample of either log, over
// the first open of a relaunch bound, and that a cold open in a fresh
// isolate replays the same file into the same ledger as a warm relaunch.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

import '../../data/name_replay_perf_test.dart'
    show coldSample, fastestOpenMs, relaunchMs;
import 'durability_restart_test.dart' show expectSameSnapshot;
import 'performance_test.dart' as perf;
import 'qa_data_harness.dart';
import 'r15_regression_test.dart' show logPhone;
import 'r17_regression_test.dart' show memberCreates;
import 'r18_regression_test.dart' show astralName;
import 'r19_probe_test.dart'
    show ColdOpen, coldRelaunches, expectColdRelaunchWithinBudget;
import 'r32_perf_load_test.dart' show underLoad;

void main() {
  test('the cold relaunch bound holds when bursts of load fall on a control '
      'open and on a different astral open (DATA-R32-02 class)', () async {
    final loaded = <String>[];
    final r = await coldRelaunches(
      around: (run, astral, open) async {
        // Load over the first control open and the second astral open:
        // each log keeps unloaded samples, at different points in time.
        final hit = astral ? run == 1 : run == 0;
        if (!hit) return open();
        final ColdOpen o = await underLoad(open);
        loaded.add('${astral ? 'astral' : 'control'} run $run ${o.openMs} ms');
        return o;
      },
    );
    // ignore: avoid_print
    print(
      '[r34] cold relaunch, two bursts: control '
      '${[for (final o in r.control) o.openMs]}; astral '
      '${[for (final o in r.astral) o.openMs]}; loaded $loaded',
    );
    expect(loaded, hasLength(2));
    expectColdRelaunchWithinBudget(r);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a relaunch bound (fastestOpenMs over relaunchMs) holds when a burst '
      'of load falls on its first open: 20k ops open within 2 s '
      '(DATA-R32-02 class)', () async {
    final r = await logPhone(const []);
    var loadedMs = 0;
    final ms = await fastestOpenMs((run) async {
      if (run != 0) return relaunchMs(r.phone);
      return loadedMs = await underLoad(() => relaunchMs(r.phone));
    });
    // ignore: avoid_print
    print(
      '[r34] 20k ops: first open ${r.openMs} ms, loaded relaunch $loadedMs '
      'ms, fastest $ms ms',
    );
    expect(r.phone.snap.ops, hasLength(perf.kTotalOps));
    expect(ms, lessThan(2000));
    await r.phone.close();
    r.phone.dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a cold open in a fresh isolate replays the same file into the same '
      'ledger as a warm relaunch here: astral names, canonical state, op '
      'order, unshared counts, device id (coldSample is a faithful '
      'relaunch)', () async {
    const n = 3000;
    final r = await logPhone(memberCreates(n, astralName), base: false);
    final dir = r.phone.dir;
    // Warm: this isolate has shown the names once already.
    for (var i = 1; i <= 50; i++) {
      NameText.display(astralName(i));
    }
    await r.phone.restart();
    final warm = r.phone.snap;
    await r.phone.close();
    final cold = await coldSample(() async {
      final tables = NameText.astralEntries;
      resetKeystore();
      final p = FilePhone(dir);
      for (var gi = 0; gi < perf.kGroups; gi++) {
        await p.keys.put('group-$gi', Uint8List.fromList(List.filled(32, gi)));
      }
      await p.launch();
      final s = p.snap;
      await p.close();
      return (
        tables: tables,
        state: s.state.toCanonicalJson(),
        ops: [for (final o in s.ops) o.id],
        unsharedOpIds: s.unsharedOpIds,
        unsharedCounts: s.unsharedCounts,
        device: s.localDeviceId,
      );
    });
    expect(cold.tables, 0, reason: 'the fresh isolate starts cold');
    expect(cold.state, warm.state.toCanonicalJson());
    expect(cold.ops, [for (final o in warm.ops) o.id]);
    expect(cold.unsharedOpIds, warm.unsharedOpIds);
    expect(cold.unsharedCounts, warm.unsharedCounts);
    expect(cold.device, warm.localDeviceId);
    // And the warm relaunch matches a third launch here.
    await r.phone.launch();
    expectSameSnapshot(r.phone.snap, warm);
    expect(
      r.phone.group('group-1').members.keys.where((m) => m.startsWith('r17-m')),
      hasLength(n),
    );
    await r.phone.close();
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
