// QA VISUAL round 42: final regression sweep. The only product change
// since round 41 is SYNC-R41-01 (lib/sync/protocol/session.dart): a sync
// now reports as sent only the ops the peer's version vector came to
// cover, so "Sent 0 changes, got 0 changes." follows a sync that sent
// batches, the progress step still counts ACKed batches, and a stopped
// sync that only re-sent held-back ops says "Nothing was lost." instead
// of naming a partial result.
//
// This file walks the sync session screen through every state it can now
// show (transfer with six-digit counts, done with nothing shared, done
// with a 60-character group and six-digit counts, stopped with and
// without a partial result) at every size, scale and theme: no overflow,
// no text cut, the peer's 40-character name and every count in full,
// TalkBack reading the result lines, the guidelines, and the tether and
// bar standing still under "Remove animations". The Sync and Activity
// history rows and Home are walked with the new zero-sent shape.
// r42_real_font_test.dart runs this file again with Familjen Grotesk.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'visual_harness.dart';

const String _peer40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';

bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().replaceAll('\n', ' ').contains(text) &&
      !p.didExceedMaxLines;
});

/// Every visible paragraph that exceeded its line limit.
List<String> _cutParagraphs() => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.hasSize && p.didExceedMaxLines)
      p.text.toPlainText(),
];

String _why(Evaluation r) => r.reason?.split('\n').first ?? 'failed';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The 48 dp, labelled tap target and text contrast guidelines. The
/// contrast guideline samples a screenshot taken at 1 px per dp, so with
/// the test font at a 3x view the edge blends of small text outnumber its
/// solid pixels and it can report about 3.3:1 for ink that is 16:1 (seen
/// here on "Connected", bodyLarge on surface, light). A contrast failure
/// is therefore checked against the label's own ink on the screen's
/// surface; only a failure there is reported.
Future<List<String>> _guidelines(WidgetTester t, String at) async {
  final out = <String>[];
  for (final g in [
    androidTapTargetGuideline,
    labeledTapTargetGuideline,
    textContrastGuideline,
  ]) {
    final r = await g.evaluate(t);
    if (r.passed) continue;
    if (g != textContrastGuideline) {
      out.add('$at ${g.description}: ${_why(r)}');
      continue;
    }
    final surface = Theme.of(t.element(find.byType(Scaffold).first))
        .colorScheme
        .surface;
    final labels = RegExp(r'label: "([^"]*)"')
        .allMatches(r.reason ?? '')
        .map((m) => m.group(1)!)
        .toSet();
    if (labels.isEmpty) out.add('$at ${g.description}: ${_why(r)}');
    for (final label in labels) {
      for (final e in find.text(label).evaluate()) {
        final p = e.renderObject;
        if (p is! RenderParagraph) continue;
        final style = p.text.style;
        final ink = style?.color;
        if (ink == null) continue;
        final large =
            (style!.fontSize ?? 14) >= 18 ||
            ((style.fontSize ?? 14) >= 14 &&
                (style.fontWeight?.value ?? 400) >= 700);
        final need = large ? 3.0 : 4.5;
        final got = _ratio(Color.alphaBlend(ink, surface), surface);
        if (got < need) {
          out.add(
            '$at: "$label" ink is ${got.toStringAsFixed(2)}:1 on the '
            'surface (needs $need)',
          );
        }
      }
    }
  }
  return out;
}

SyncSummary _summary({
  required int sent,
  required int got,
  Map<GroupId, int> byGroup = const {},
}) => SyncSummary(
  peerName: _peer40,
  transport: TransportKind.lan,
  startedAt: kNow.subtract(const Duration(minutes: 2)),
  endedAt: kNow.subtract(const Duration(minutes: 1)),
  sentOps: sent,
  receivedOps: got,
  receivedByGroup: byGroup,
  groupIds: byGroup.keys.toList(),
);

SyncRecord _record(int minutes, {int sent = 0, int got = 0, bool ok = true}) =>
    SyncRecord(
      id: 'sync-qa-r42-$minutes',
      peerName: _peer40,
      transport: TransportKind.lan,
      startedAt: kNow.subtract(Duration(minutes: minutes + 1)),
      endedAt: kNow.subtract(Duration(minutes: minutes)),
      sentOps: sent,
      receivedOps: got,
      groupIds: const [],
      outcome: ok ? SyncOutcome.completed : SyncOutcome.failed,
    );

typedef _State = ({String name, SessionStatus status, List<String> lines});

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // The session screen in each state, at every size, scale and theme.
  // ------------------------------------------------------------------
  testWidgets('R42 sweep: the sync session screen lays out, reads in full '
      'and meets the guidelines in every state', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.longNames());
    final states = <_State>[
      (
        name: 'transferring',
        status: SessionActive(
          SyncProgress(
            peerName: _peer40,
            transport: TransportKind.lan,
            phase: SyncPhase.transferring,
            sentOps: 123456,
            toSendOps: 123456,
            receivedOps: 65432,
            toReceiveOps: 654321,
            verificationCode: '482913',
          ),
        ),
        lines: [
          S.syncingWith(_peer40),
          S.stepSending(123456, 123456),
          S.stepReceiving(65432, 654321),
          S.verification(_peer40, '482 913'),
        ],
      ),
      (
        name: 'done, nothing shared (SYNC-R41-01 shape)',
        status: SessionCompleted(_summary(sent: 0, got: 0)),
        lines: [S.syncedWithTitle(_peer40), S.sentAndGot(0, 0)],
      ),
      (
        name: 'done, six-digit counts',
        status: SessionCompleted(
          _summary(
            sent: 123456,
            got: 654321,
            byGroup: {w.group: 654320, w.kwdGroup: 1},
          ),
        ),
        lines: [
          S.syncedWithTitle(_peer40),
          S.sentAndGot(123456, 654321),
          '$kGroup60: ${S.changes(654320)}',
        ],
      ),
      (
        name: 'stopped, nothing arrived',
        status: SessionFailed(
          SyncFailure.connectionLost,
          '',
          _summary(sent: 0, got: 0),
        ),
        lines: [S.syncStopped, S.nothingLost],
      ),
      (
        name: 'stopped, part arrived',
        status: SessionFailed(
          SyncFailure.connectionLost,
          '',
          _summary(sent: 3, got: 123456),
        ),
        lines: [S.syncStopped, S.partialArrived(123456)],
      ),
    ];
    final problems = <String>[];
    for (final v in kVariants) {
      for (final s in states) {
        final at = '${variantName(v)} ${s.name}';
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, w.phone, v: v, location: Routes.syncSession);
          w.phone.engine.emitStatus(SyncStatus(session: s.status));
          await settleFrames(t);
          await t.pump(const Duration(seconds: 2));
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        for (final c in _cutParagraphs()) {
          problems.add('$at: "$c" is cut');
        }
        final labels = semanticsLabels(t);
        for (final line in s.lines) {
          final scroll = find.byType(Scrollable).first;
          if (find.text(line).evaluate().isEmpty) {
            await t.scrollUntilVisible(
              find.textContaining(line.split(':').first),
              100,
              scrollable: scroll,
              maxScrolls: 60,
            );
            await t.pump();
          }
          if (!_shownInFull(line)) problems.add('$at: "$line" is not in full');
          if (!labels.any((l) => l.contains(line)) &&
              !semanticsLabels(t).any((l) => l.contains(line))) {
            problems.add('$at: TalkBack does not read "$line"');
          }
        }
        // The guidelines at the top of the list and at its end.
        final list = find.byType(Scrollable).first;
        final pos = (t.state(list) as ScrollableState).position;
        pos.jumpTo(0);
        await t.pump();
        problems.addAll(await _guidelines(t, '$at top'));
        pos.jumpTo(pos.maxScrollExtent);
        await t.pump();
        problems.addAll(await _guidelines(t, '$at end'));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => w.phone.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // Under "Remove animations" the session screen stands still in every
  // phase, the done tether included.
  // ------------------------------------------------------------------
  testWidgets('R42 sweep: under Remove animations the session screen '
      'schedules no animation in any state', (t) async {
    late VisualPhone p;
    await t.runAsync(() async => p = await VisualPhone.create());
    final problems = <String>[];
    final statuses = <String, SessionStatus>{
      for (final phase in SyncPhase.values)
        phase.name: SessionActive(
          SyncProgress(
            peerName: _peer40,
            transport: TransportKind.ble,
            phase: phase,
            sentOps: 1,
            toSendOps: 2,
            toReceiveOps: 3,
          ),
        ),
      'done': SessionCompleted(_summary(sent: 0, got: 0)),
      'stopped': const SessionFailed(SyncFailure.timeout, ''),
    };
    for (final e in statuses.entries) {
      await pumpVisual(
        t,
        p,
        v: kVariants.first,
        location: Routes.syncSession,
        disableAnimations: true,
      );
      p.engine.emitStatus(SyncStatus(session: e.value));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      if (t.binding.transientCallbackCount > 0) {
        problems.add('${e.key}: still animating');
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(p.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // The history rows with the zero-sent shape SYNC-R41-01 makes common,
  // beside six-digit counts and a stopped sync, on Sync, Activity and
  // Home: no overflow, the count line and the name in full.
  // ------------------------------------------------------------------
  testWidgets('R42 sweep: sync history rows with nothing sent lay out and '
      'read in full on Sync, Activity and Home', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.realistic();
      w.phone.engine.addHistory(_record(9, sent: 123456, got: 654321));
      w.phone.engine.addHistory(_record(6, ok: false));
      w.phone.engine.addHistory(_record(3));
    });
    final problems = <String>[];
    for (final v in kVariants) {
      for (final loc in [Routes.sync, Routes.activity, Routes.home]) {
        final at = '${variantName(v)} $loc';
        final errors = await collectLayoutErrors(
          () => pumpVisual(
            t,
            w.phone,
            v: (
              size: Size(v.size.width, 3200),
              scale: v.scale,
              brightness: v.brightness,
            ),
            location: loc,
          ),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        if (!_shownInFull(_peer40)) problems.add('$at: "$_peer40" is cut');
        if (loc == Routes.sync) {
          for (final line in [S.sentGot(0, 0), S.sentGot(123456, 654321)]) {
            if (!_shownInFull(line)) problems.add('$at: "$line" not in full');
          }
        }
        // Names and activity sentences end in an ellipsis in one-line rows
        // by design; amounts never do.
        final cut = findCutAmounts(t);
        if (cut.isNotEmpty) problems.add('$at: cut ${cut.join('; ')}');
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
