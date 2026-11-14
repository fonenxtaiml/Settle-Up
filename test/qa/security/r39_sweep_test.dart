// QA SECURITY round 39: final regression sweep on qa/integration (d91d1e1).
//
// Since round 29 the security-relevant changes are the own-clock lead
// (OpFactory.maxLeadMs, DATA-R29-01), the clock notice (DATA-R29-02,
// DATA-R31-01, DATA-R32-01) and the UI rounds that show names in full
// (VISUAL-R34-02, VISUAL-R36-01, VISUAL-R38-01). The first two are probed
// here against hostile peers; the last one changes what a name another
// phone sends can do on screen.
//
// SECURITY-R39-01: Sync's "Recent syncs" rows and Activity's "Synced
// with ..." rows now wrap a phone's name in full, on the premise that
// phone names are at most 40 characters (SPEC 5.16). That holds for names
// typed on a phone, not for names received: a connect link from any web
// page or chat carries an `n` cut only to kMaxPeerNameUnits (960) code
// units, and a HELLO name may be 100 units. One tap on such a link records
// the name in Sync history, where it now fills the screen.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/op_factory.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/local_address.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/ui/router.dart';

import '../sync/qa_phone.dart';
import '../visual/visual_harness.dart';

/// The longest phone name this app lets anyone type (SPEC 5.16).
const int _phoneNameChars = 40;

/// A hostile connect-link name: 200 words, 1,199 characters before the
/// link-name bound.
final String _hostileName = List.filled(200, 'Pixel').join(' ');

String _connectLink(String name) =>
    'settleup://sync?v=1&h=192.168.43.1:47321&d=dev-hostile'
    '&n=${Uri.encodeQueryComponent(name)}';

void main() {
  group('clock lead and notice against hostile peers (DATA-R29-01..R32-01)',
      () {
    test('the 5-day own lead sits inside the window peers accept', () {
      expect(OpFactory.maxLeadMs, lessThan(Ledger.maxRemoteAheadMs));
      expect(HlcClock.maxForwardDriftMs, lessThan(OpFactory.maxLeadMs));
    });

    test('a peer floor ahead raises the notice; my own floor does not, and '
        'a floor past the adopt window is never adopted', () {
      const me = 'dev-me';
      const now = 1_800_000_000_000;
      const ahead = now + 2 * HlcClock.maxForwardDriftMs;
      final peer = HlcClock(deviceId: me, nowMillis: () => now);
      final a = peer.tickAfter(const Hlc(ahead, 0, 'dev-peer'));
      expect(peer.skewDetected, isTrue);
      expect(a.deviceId, me);
      expect(a.millis, ahead);
      // A peer cannot plant a stamp under my device id: the Ledger refuses
      // remote ops with it (_checkOwnOps, covered in op_validation_test).
      final own = HlcClock(deviceId: me, nowMillis: () => now)
        ..tickAfter(const Hlc(ahead, 0, me));
      expect(own.skewDetected, isFalse);
      // A hostile floor a year ahead cannot drag this clock with it.
      final far = HlcClock(deviceId: me, nowMillis: () => now);
      final f = far.tickAfter(
        const Hlc(now + 365 * 24 * 3600 * 1000, 0, 'dev-peer'),
      );
      expect(f.millis, now);
    });
  });

  group('names another phone sends, shown in full (VISUAL-R36-01)', () {
    late MemoryTransportHub hub;
    final phones = <QaPhone>[];
    setUp(() => hub = MemoryTransportHub());
    tearDown(() async {
      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
    });

    test('a link may still dial only local-network hosts (SPEC 8.6)', () {
      for (final h in [
        '192.168.43.1:47321',
        '10.0.0.9:1',
        '172.16.0.1:2',
        '[fe80::1]:3',
        '127.0.0.1:4',
      ]) {
        expect(isLocalNetworkHostPort(h), isTrue, reason: h);
      }
      for (final h in [
        '8.8.8.8:443',
        '172.32.0.1:1',
        '0.0.0.0:1',
        '[::ffff:8.8.8.8]:443',
        '[2001:4860::8888]:443',
        'evil.example.com:443',
        '192.168.1.1.evil.example:1',
        '',
      ]) {
        expect(isLocalNetworkHostPort(h), isFalse, reason: h);
      }
    });

    test(
      'a connect link records a phone name no longer than a phone name',
      () async {
        final alex = await QaPhone.create(hub, 'a', "Alex's Pixel");
        phones.add(alex);
        await expectLater(
          alex.engine.syncWithLink(_connectLink(_hostileName)),
          throwsA(isA<SyncException>()),
        );
        final r = (await alex.records()).single;
        expect(
          r.peerName.characters.length,
          lessThanOrEqualTo(_phoneNameChars),
          reason: 'recorded ${r.peerName.length} code units',
        );
      },
    );
  });

  testWidgets(
    'a hostile linked name takes at most a few lines in Recent syncs',
    (t) async {
      late VisualWorld w;
      // What the engine records for that link (the link-name bound).
      final recorded = shownPeerName(_hostileName);
      await t.runAsync(() async {
        w = await VisualWorld.realistic();
        w.phone.engine.addHistory(SyncRecord(
          id: 'sync-hostile',
          peerName: recorded,
          transport: TransportKind.lan,
          startedAt: kNow.subtract(const Duration(minutes: 3)),
          endedAt: kNow.subtract(const Duration(minutes: 2)),
          sentOps: 0,
          receivedOps: 0,
          groupIds: const [],
          outcome: SyncOutcome.failed,
        ));
      });
      const v = (
        size: Size(360, 800),
        scale: 1.0,
        brightness: Brightness.light,
      );
      await pumpVisual(t, w.phone, v: v, location: Routes.sync);
      final rows = find.byType(RichText).evaluate().where((e) {
        final p = e.renderObject;
        return p is RenderParagraph &&
            p.text.toPlainText().startsWith('Pixel Pixel');
      });
      expect(rows, isNotEmpty);
      final p = rows.first.renderObject! as RenderParagraph;
      final painter = TextPainter(
        text: p.text,
        textDirection: TextDirection.ltr,
        textScaler: p.textScaler,
      )..layout(maxWidth: p.size.width);
      final lines = painter.computeLineMetrics().length;
      painter.dispose();
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(() => w.phone.dispose());
      // A 40-character name wraps to two or three lines at this width.
      expect(lines, lessThanOrEqualTo(3), reason: '$lines lines');
    },
  );
}
