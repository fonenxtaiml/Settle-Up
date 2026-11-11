// QA SECURITY round 21: final regression sweep of the security area on
// qa/integration (967014f).
//
// Probes the name normaliser added since the last security round
// (NormalForm, NameText.fit and display) with hostile code points, checks
// that peer names from links and HELLO stay well formed, and holds the
// repro of SECURITY-R21-01: a peer's text may carry a lone UTF-16
// surrogate, which the remote check accepts and the screens then hand to
// the text engine, which refuses it ("string is not well-formed UTF-16")
// and draws the whole line as one U+FFFD.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/ui/dev/seed_data.dart';
import 'package:settle_up/ui/router.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';
import '../../ui/screens/screen_harness.dart';
import 'op_validation_test.dart' show mallory, sendRawOps;

/// Whether [s] is well-formed UTF-16: every surrogate is half of a pair.
bool wellFormed(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < s.length) {
        final d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          i++;
          continue;
        }
      }
      return false;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) return false;
  }
  return true;
}

bool hasBidiOrControl(String s) => s.runes.any(
  (r) =>
      (r < 0x20) ||
      (r >= 0x7F && r <= 0x9F) ||
      r == 0x061C ||
      r == 0x200E ||
      r == 0x200F ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2066 && r <= 0x2069),
);

/// Code units a hostile name is built from: letters, bidi controls,
/// joiners, marks, Hangul jamo (and the edge past the last syllable),
/// compatibility characters that grow under NFKC, noncharacters, astral
/// letters, marks, emoji and tags, and both halves of surrogate pairs on
/// their own.
const List<String> _pool = [
  'a',
  'Z',
  '7',
  ' ',
  '.',
  '=',
  '\u00E9',
  'e\u0301',
  '\u0301',
  '\u0F77',
  '\u093C',
  '\u0915\u094D',
  '\u0628',
  '\u200C',
  '\u200D',
  '\u200B',
  '\u2060',
  '\u00AD',
  '\u202E',
  '\u202D',
  '\u2066',
  '\u2069',
  '\u200F',
  '\u061C',
  '\u0000',
  '\u001B',
  '\u0085',
  '\u2028',
  '\u3164',
  '\u115F',
  '\u1100',
  '\u1161',
  '\u11A8',
  '\uAC00',
  '\uD7A3',
  '\uD7A4',
  '\uFDFA',
  '\u337F',
  '\uFF21',
  '\u2026',
  '\uFE0F',
  '\uFFFE',
  '\uFFFF',
  '\uFFFD',
  '\uFEFF',
  '\u{1D400}',
  '\u{1D165}',
  '\u{1F469}',
  '\u{1F3F4}',
  '\u{E0067}',
  '\u{E0001}',
  '\u{10FFFF}',
  '\uD800',
  '\uDBFF',
  '\uDC00',
  '\uDFFF',
];

String _hostile(Random rnd) {
  final b = StringBuffer();
  final n = 1 + rnd.nextInt(60);
  for (var i = 0; i < n; i++) {
    b.write(_pool[rnd.nextInt(_pool.length)]);
  }
  return b.toString();
}

void main() {
  group('round 21 sweep: name normaliser under hostile input', () {
    test('fit, display and normalize never throw, keep no bidi or control '
        'characters and stay within the limit', () {
      final rnd = Random(21);
      for (var i = 0; i < 4000; i++) {
        final raw = _hostile(rnd);
        for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
          final fit = NameText.fit(raw, limit);
          expect(wellFormed(fit), isTrue, reason: raw.codeUnits.toString());
          expect(
            hasBidiOrControl(fit),
            isFalse,
            reason: raw.codeUnits.toString(),
          );
          expect(
            NameText.fits(fit, limit),
            isTrue,
            reason: raw.codeUnits.toString(),
          );
          expect(
            NameText.fit(fit, limit),
            fit,
            reason: 'idempotent: ${raw.codeUnits}',
          );
          final shown = NameText.display(raw, limit);
          expect(
            hasBidiOrControl(shown),
            isFalse,
            reason: raw.codeUnits.toString(),
          );
        }
        final n = NameText.normalize(raw);
        expect(wellFormed(n), isTrue, reason: raw.codeUnits.toString());
        expect(NameText.normalize(n), n, reason: raw.codeUnits.toString());
      }
    });

    test('peer names from HELLO and links are bounded, well formed and free '
        'of bidi characters', () {
      final rnd = Random(2121);
      for (var i = 0; i < 2000; i++) {
        final raw = _hostile(rnd) * (1 + rnd.nextInt(40));
        final shown = shownPeerName(raw);
        expect(wellFormed(shown), isTrue, reason: raw.codeUnits.toString());
        expect(hasBidiOrControl(shown), isFalse);
        expect(
          cleanPeerName(raw).length,
          lessThanOrEqualTo(kMaxPeerNameUnits * 18),
        );
        expect(peerLabel([raw]).isNotEmpty, isTrue);
      }
      // A link's names are percent-encoded; a lone surrogate cannot be
      // percent-encoded as UTF-8, so the link parser never sees one, and
      // what it shows is well formed.
      final key = base64Url
          .encode(Uint8List(32)..fillRange(0, 32, 7))
          .replaceAll('=', '');
      final link =
          'settleup://join?v=1&g=0190f0e0-0000-7000-8000-000000000001'
          '&k=$key&n=${Uri.encodeQueryComponent('Goa\u202E trip')}'
          '&c=INR&f=${Uri.encodeQueryComponent('Al\u200Bex\u2066')}';
      final parsed = InviteLink.tryParse(link);
      if (parsed != null) {
        expect(hasBidiOrControl(parsed.groupName), isFalse);
        expect(hasBidiOrControl(parsed.fromName), isFalse);
        expect(wellFormed(parsed.groupName), isTrue);
      }
    });
  });

  group('SECURITY-R21-01: lone surrogates in peer text', () {
    test(
      'the remote check accepts text that is not well-formed UTF-16',
      () {
        // What the peer sends in the JSON of an OPS frame: "\ud800" is valid
        // JSON and decodes to a lone surrogate.
        final decoded = (jsonDecode(r'{"n":"\ud800"}') as Map)['n'] as String;
        expect(wellFormed(decoded), isFalse);
        Operation op(EntityType type, String field) => Operation(
          id: 'o-$field',
          groupId: 'g',
          deviceId: 'd',
          counter: 1,
          hlc: const Hlc(1, 0, 'd'),
          entityType: type,
          entityId: type == EntityType.group ? 'g' : 'e',
          kind: OpKind.update,
          payload: {field: decoded},
        );
        final accepted = <String>[
          for (final (type, field) in [
            (EntityType.member, MemberFields.displayName),
            (EntityType.group, GroupFields.name),
            (EntityType.expense, ExpenseFields.description),
            (EntityType.expense, ExpenseFields.notes),
          ])
            if (TextRules.remoteProblem(op(type, field)) == null) field,
        ];
        expect(
          accepted,
          isEmpty,
          reason: 'remote check accepts a lone surrogate in $accepted',
        );
      },
      skip:
          'QA SECURITY-R21-01: Peer text with a lone UTF-16 surrogate is '
          'accepted and blanks whole lines on screen',
    );

    test(
      'a member name and an expense description with a lone surrogate '
      'sent by a key holder are refused, or shown well formed',
      () async {
        final alex = await TestPhone.create('a', deviceName: 'Alex');
        final priya = await TestPhone.create(
          'b',
          deviceName: 'Priya',
          name: 'Priya',
        );
        addTearDown(alex.close);
        addTearDown(priya.close);
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        final (ri, rr) = await syncPair(alex, priya);
        expect(ri.isSuccess && rr.isSuccess, isTrue);

        final (ci, cr) = await channelPair();
        final session = SyncSession(
          channel: cr,
          store: priya.store,
          role: SessionRole.responder,
          timings: fastTimings,
        );
        final result = session.run();
        final evil = EvilPeer(ci, initiator: true);
        await evil.handshake({
          seed.g: await alex.keyOf(seed.g),
        }, deviceId: mallory);
        final memberOp = alex
            .opsOf(seed.g)
            .firstWhere((o) => o.entityType == EntityType.member);
        final expenseOp = alex.opsOf(seed.g).last;
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            {
              ...memberOp.toJson(),
              'id': 'r21-member',
              'deviceId': mallory,
              'counter': 1,
              'hlc': Hlc(kBaseMs + 9000, 0, mallory).encode(),
              'entityId': 'member-r21',
              'payload': {
                ...memberOp.payload,
                MemberFields.displayName: '\uD800',
                MemberFields.personId: 'person-r21',
              },
            },
            {
              ...expenseOp.toJson(),
              'id': 'r21-expense',
              'deviceId': mallory,
              'counter': 2,
              'hlc': Hlc(kBaseMs + 9001, 0, mallory).encode(),
              'entityId': 'expense-r21',
              'payload': {
                ...expenseOp.payload,
                ExpenseFields.description: '\uDC00',
              },
            },
          ],
          'more': false,
        });
        final reply = await evil.until(
          (m) => m is ErrorMessage || m is AckMessage,
        );
        await evil.close();
        await result;
        final g = priya.state.groups[seed.g]!;
        final name = g.members['member-r21']?.displayName;
        final description = g.expenses['expense-r21']?.description;
        expect(
          (name == null || wellFormed(name)) &&
              (description == null || wellFormed(description)),
          isTrue,
          reason:
              'reply ${reply.runtimeType}; stored name '
              '${name?.codeUnits}, description ${description?.codeUnits}',
        );
      },
      skip:
          'QA SECURITY-R21-01: Peer text with a lone UTF-16 surrogate is '
          'accepted and blanks whole lines on screen',
    );

    testWidgets('QA SECURITY-R21-01: the group screen draws a peer member with a lone surrogate '
        'in its name without a text engine error', (tester) async {
      phoneView(tester);
      final w = await TestWorld.demo();
      await pumpApp(tester, w);
      final g = w.g.goa;
      final members = w.ledger.current.state.groups[g]!.members.keys.toList();
      // The fake ledger stores text as the real one stores a peer's op.
      await w.ledger.actAs(
        device: DemoIds.priyaPhone,
        person: DemoIds.priya,
        at: DateTime.utc(2026, 11, 1),
        body: () async {
          final mid = await w.ledger.addMember(g, displayName: '\uD800');
          await w.ledger.addExpense(
            ExpenseDraft(
              groupId: g,
              description: 'Taxi',
              total: 100,
              currency: 'INR',
              paidBy: SplitSpec.single(mid, 100),
              owedBy: SplitSpec.equal([...members, mid]),
              category: 'food',
              date: DateTime.utc(2026, 11, 1),
            ),
          );
        },
      );
      w.go(Routes.group(g));
      await settle(tester);
      // Lines such as "Isha pays <name>" and "<name> paid Rs 1" are one
      // span each; the text engine refuses the span and a release build
      // draws the whole line as a single U+FFFD.
      final bad = <String>[];
      for (final el in find.byType(RichText).evaluate()) {
        (el.widget as RichText).text.visitChildren((span) {
          if (span is TextSpan &&
              span.text != null &&
              !wellFormed(span.text!)) {
            bad.add(span.text!.replaceAll(RegExp('[\uD800-\uDFFF]'), '<?>'));
          }
          return true;
        });
      }
      final error = tester.takeException();
      expect(bad, isEmpty, reason: 'ill-formed spans: $bad');
      expect(error, isNull);
    }, skip: true); // QA SECURITY-R21-01: Peer text with a lone UTF-16 surrogate is accepted and blanks whole lines on screen
  });
}
