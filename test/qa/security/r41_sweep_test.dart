// QA SECURITY round 41: reverification of SECURITY-R39-01 on qa/integration
// (7f1526a) and a sweep of the defect class: every name another phone
// sends (connect link `n`, invite link `f` and `n`, advert names, Sync
// history read back from storage) is shown and recorded no longer than a
// name typed on a phone (40 characters, 60 for a group; SPEC 5.16), and
// it shows no bidi controls or invisibles that typed names cannot hold.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/codecs.dart';
import 'package:settle_up/sync/nearby_registry.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/router.dart';

import '../visual/visual_harness.dart';

/// Hostile names of the shapes a stranger's link or advert may carry.
final Map<String, String> _hostile = {
  'words': List.filled(200, 'Pixel').join(' '),
  'rtl override': '\u202E${List.filled(150, 'lexiP').join(' ')}\u202C',
  'emoji ZWJ chains': List.filled(120, '👩\u200D💻').join(' '),
  'zalgo': List.filled(60, 'P${'\u0301' * 40}').join(),
  'NFKC growth': '\uFDFA' * 60,
  'line breaks': List.filled(100, 'Pixel\n').join(),
};

void _expectFits(String shown, int limit, String why) {
  expect(shown.characters.length, lessThanOrEqualTo(limit), reason: why);
  expect(shown.length, lessThanOrEqualTo(limit * NameText.unitsPerChar),
      reason: why);
  expect(shown.runes.where((r) => r == 0x202E || r == 0x202C || r == 0x0A),
      isEmpty,
      reason: '$why: bidi overrides and line breaks are left out');
  // Shown as this phone would save the same text typed.
  expect(shown, NameText.fit(shown, limit), reason: why);
}

void main() {
  group('received names fit a typed name (SECURITY-R39-01 class)', () {
    test('connect link n', () {
      for (final MapEntry(:key, :value) in _hostile.entries) {
        final link = 'settleup://sync?v=1&h=192.168.43.1:47321&d=dev-x'
            '&n=${Uri.encodeQueryComponent(value)}';
        final c = ConnectLink.tryParse(link);
        expect(c, isNotNull, reason: key);
        _expectFits(c!.deviceName, NameText.maxLength, key);
      }
    });

    test('invite link f and n', () {
      for (final MapEntry(:key, :value) in _hostile.entries) {
        final link = InviteLink(
          groupId: 'g-1',
          groupKey: Uint8List(32),
          groupName: value,
          currency: 'INR',
          fromName: value,
        ).encode();
        final i = InviteLink.tryParse(link);
        expect(i, isNotNull, reason: key);
        _expectFits(i!.fromName, NameText.maxLength, '$key (f)');
        _expectFits(i.groupName, NameText.maxGroupLength, '$key (n)');
      }
    });

    test('advert names in the Nearby list', () {
      final t0 = DateTime.utc(2026, 11, 14, 12);
      final r = NearbyRegistry();
      var port = 1;
      for (final MapEntry(:key, :value) in _hostile.entries) {
        for (final kind in [TransportKind.lan, TransportKind.ble]) {
          r.update(
            DiscoveredPeer(
              kind: kind,
              address: '10.0.0.${port++}:1',
              name: value,
            ),
            t0,
          );
        }
        expect(r.peers, isNotEmpty, reason: key);
      }
      for (final p in r.peers) {
        _expectFits(p.name, NameText.maxLength, 'advert ${p.key}');
      }
    });

    test('Sync history stored by an earlier build reads back cut', () {
      for (final MapEntry(:key, :value) in _hostile.entries) {
        final stored = syncRecordToJson(SyncRecord(
          id: 'r-$key',
          peerName: value,
          transport: TransportKind.lan,
          startedAt: DateTime.utc(2026, 11, 1),
          endedAt: DateTime.utc(2026, 11, 1, 0, 1),
          sentOps: 0,
          receivedOps: 0,
          groupIds: const [],
          outcome: SyncOutcome.failed,
        ));
        final back = syncRecordFromJson(stored);
        expect(back, isNotNull, reason: key);
        expect(back!.peerName.characters.length,
            lessThanOrEqualTo(NameText.maxLength),
            reason: key);
        expect(back.peerName, isNotEmpty, reason: key);
      }
    });
  });

  testWidgets(
    "a hostile linked name takes at most a few lines in Activity's feed",
    (t) async {
      late VisualWorld w;
      final recorded = shownPeerName(_hostile['words']!);
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
      await pumpVisual(t, w.phone, v: v, location: Routes.activity);
      final rows = find.byType(RichText).evaluate().where((e) {
        final p = e.renderObject;
        return p is RenderParagraph &&
            p.text.toPlainText().contains('Pixel Pixel');
      }).toList();
      var lines = 0;
      for (final e in rows) {
        final p = e.renderObject! as RenderParagraph;
        final painter = TextPainter(
          text: p.text,
          textDirection: TextDirection.ltr,
          textScaler: p.textScaler,
        )..layout(maxWidth: p.size.width);
        final n = painter.computeLineMetrics().length;
        painter.dispose();
        if (n > lines) lines = n;
      }
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(() => w.phone.dispose());
      expect(rows, isNotEmpty, reason: 'the Synced with row is shown');
      expect(lines, lessThanOrEqualTo(3), reason: '$lines lines');
    },
  );
}
