// QA SYNC-R1: a large group through the real engine over BLE-size frames.
// 2,000+ ops, 50 members, 16 KiB frames: the 4-batch window holds, progress
// is rate limited and monotonic, and both phones end equal.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/protocol/batching.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';
import 'qa_taps.dart';

const SessionTimings _timings = SessionTimings(
  handshakeTimeout: Duration(seconds: 5),
  idleTimeout: Duration(seconds: 10),
  pingAfter: Duration(seconds: 2),
  liveIdleTimeout: Duration(seconds: 10),
  livePingEvery: Duration(seconds: 2),
  closeTimeout: Duration(milliseconds: 500),
  progressInterval: Duration(milliseconds: 100),
  liveFlushDelay: Duration(milliseconds: 50),
  tick: Duration(milliseconds: 25),
);

void main() {
  test(
    '2,000+ ops, 50 members, 16 KiB frames: window, progress, convergence',
    () async {
      final hub = MemoryTransportHub(latency: const Duration(milliseconds: 2));
      late TapTransport tap;
      final alex = await QaPhone.create(
        hub,
        'a',
        "Alex's Pixel",
        kinds: const [TransportKind.ble],
        maxFrameBytes: const {TransportKind.ble: 16384},
        timings: _timings,
        wrap: (t) => tap = TapTransport(t),
      );
      final priya = await QaPhone.create(
        hub,
        'b',
        "Priya's Pixel",
        kinds: const [TransportKind.ble],
        maxFrameBytes: const {TransportKind.ble: 16384},
        timings: _timings,
      );
      addTearDown(alex.dispose);
      addTearDown(priya.dispose);

      final others = [for (var i = 1; i < 50; i++) 'Friend $i'];
      final seed = await alex.seedGroup(expenses: 0, others: others);
      final members = alex.state.groups[seed.g]!.members.keys.toList();
      expect(members, hasLength(50));
      await priya.join(alex, seed.g);
      await priya.engine.startHosting();
      await alex.engine.syncWith(await alex.find(priya));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(priya.state.groups[seed.g]!.members, hasLength(50));
      for (var i = 0; i < 2000; i++) {
        final owers = i % 10 == 0
            ? members
            : {members[i % 50], members[(i * 7 + 3) % 50]}.toList();
        await alex.addExpense(
          seed.g,
          payer: members[i % 50],
          owers: owers,
          total: 5000 + i,
          description: 'Expense $i',
        );
      }
      // Priya writes too, so both directions stream at once.
      for (var i = 0; i < 300; i++) {
        await priya.ledger.addMember(seed.g, displayName: 'Late $i');
      }
      final total = alex.opCount(seed.g) - 51; // already shared: create + 50
      const back = 300;
      expect(total, greaterThanOrEqualTo(2000));

      // Timeline of Alex's link: 'S' per frame sent, 'R' per frame received.
      final timeline = StringBuffer();
      tap
        ..onSend = (i, f) {
          timeline.write('S');
          return f;
        }
        ..onReceive = (i, f) {
          timeline.write('R');
          return f;
        };

      final progress = <(Duration, SyncProgress)>[];
      final sw = Stopwatch()..start();
      final sub = alex.engine.watchStatus().listen((s) {
        final session = s.session;
        if (session is SessionActive) {
          progress.add((sw.elapsed, session.progress));
        }
      });

      final summary = await alex.engine
          .syncWith(await alex.find(priya))
          .timeout(const Duration(minutes: 3));
      sw.stop();
      await sub.cancel();

      expect(summary.sentOps, total);
      expect(summary.receivedOps, back);
      expect(priya.canonical, alex.canonical);
      expect(priya.opCount(seed.g), alex.opCount(seed.g));

      // Window: never more than kBatchWindow OPS frames (+ DONE, a PING or
      // PONG) between two frames from the peer.
      final runs = RegExp('S+').allMatches(timeline.toString().substring(6));
      final longest = runs
          .map((m) => m.end - m.start)
          .fold(0, (a, b) => a > b ? a : b);
      expect(
        longest,
        lessThanOrEqualTo(kBatchWindow + 3),
        reason: 'longest send run $longest',
      );

      // Progress: rate limited and monotonic.
      final elapsedMs = sw.elapsedMilliseconds;
      final allowed = elapsedMs ~/ 100 + 12;
      expect(
        progress.length,
        lessThanOrEqualTo(allowed),
        reason: '${progress.length} updates in $elapsedMs ms',
      );
      var lastSent = 0, lastReceived = 0;
      for (final (_, p) in progress) {
        expect(p.sentOps, greaterThanOrEqualTo(lastSent));
        expect(p.receivedOps, greaterThanOrEqualTo(lastReceived));
        expect(
          p.sentOps,
          lessThanOrEqualTo(p.toSendOps == 0 ? total : p.toSendOps),
        );
        lastSent = p.sentOps;
        lastReceived = p.receivedOps;
      }
      final transferring = progress
          .where((e) => e.$2.phase == SyncPhase.transferring)
          .toList();
      expect(transferring, isNotEmpty);
      expect(transferring.last.$2.toSendOps, total);
      // ignore: avoid_print
      print(
        'QA scale: $total ops + ${summary.receivedOps} back in '
        '$elapsedMs ms, ${progress.length} progress updates, '
        'longest send run $longest, frames ${timeline.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
