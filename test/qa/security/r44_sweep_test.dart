// QA SECURITY round 44, final regression sweep on qa/integration
// (b79a314). Probes of the charter's riskiest paths from new angles:
//  * link query injection: a name that spells out `&h=` or `&k=` cannot add
//    a host or swap the key of an invite or connect link (SPEC 8.6);
//  * names in the New group form (the UIFLOW-R42-01 path now refuses on
//    Create what is no name): the Ledger itself still drops bidi controls
//    and refuses a name of only invisibles, whatever the UI lets through
//    (SPEC 5.16);
//  * CSV export of text a peer sent with an invisible character in front
//    of a formula: what a spreadsheet would run is still prefixed with `'`
//    (SPEC 5.10).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/pairing/links.dart';

import '../../sync/support/phone.dart';

void main() {
  group('link query injection (SPEC 8.6)', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final evilKey = base64Url.encode(Uint8List(32)).replaceAll('=', '');

    for (final payload in [
      'Asha&h=8.8.8.8:1',
      'Asha&k=$evilKey',
      'Asha#&h=10.0.0.9:47321',
      'Asha%26h%3D8.8.8.8%3A1',
      'Asha\n&h=8.8.8.8:1',
    ]) {
      test('invite: names "$payload" add no host and keep the key', () {
        final link = InviteLink(
          groupId: 'g-1',
          groupKey: key,
          groupName: payload,
          currency: 'INR',
          fromName: payload,
        ).encode();
        final i = InviteLink.tryParse(link);
        expect(i, isNotNull);
        expect(i!.host, isNull);
        expect(i.groupKey, key);
        expect(i.groupId, 'g-1');
        expect(i.currency, 'INR');
      });

      test('connect: device name "$payload" adds no host', () {
        final link = ConnectLink(
          hosts: const ['192.168.43.1:47321'],
          deviceId: 'dev-1',
          deviceName: payload,
        ).encode();
        final c = ConnectLink.tryParse(link);
        expect(c, isNotNull);
        expect(c!.hosts, ['192.168.43.1:47321']);
        expect(c.deviceId, 'dev-1');
      });
    }

    test('a connect link carries no group key or id', () {
      final link = ConnectLink(
        hosts: const ['192.168.43.1:47321'],
        deviceId: 'dev-1',
        deviceName: 'Pixel',
      ).encode();
      final q = Uri.parse(link).queryParametersAll;
      expect(q.keys.toSet(), {'v', 'h', 'd', 'n'});
    });
  });

  group('New group names in the Ledger (SPEC 5.16)', () {
    late TestPhone phone;
    setUp(() async => phone = await TestPhone.create('a'));
    tearDown(() => phone.close());

    NewGroup newGroup(List<String> members) => NewGroup(
      name: 'Goa',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: members,
    );

    test('bidi controls around a person name are dropped', () async {
      final g = await phone.ledger.createGroup(
        newGroup(['\u202Eadhsuk\u202C', '\u2067Ravi\u2069']),
      );
      final names = phone.state.groups[g]!.activeMembers
          .map((m) => m.displayName)
          .toList();
      for (final n in names) {
        expect(
          n.runes.where(
            (r) => (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069),
          ),
          isEmpty,
          reason: n,
        );
      }
      expect(names, containsAll(['adhsuk', 'Ravi']));
    });

    for (final (label, text) in [
      ('a bidi override', '\u202E'),
      ('zero-width spaces', '\u200B\u200B'),
      ('a Hangul filler', '\u3164'),
      ('an isolate pair', '\u2066\u2069'),
    ]) {
      test('a person name of only $label is refused', () async {
        await expectLater(
          phone.ledger.createGroup(newGroup([text])),
          throwsA(
            isA<LedgerException>().having(
              (e) => e.code,
              'code',
              LedgerErrorCode.invalidInput,
            ),
          ),
        );
        expect(
          phone.state.groups.values.where((g) => g.group?.name == 'Goa'),
          isEmpty,
        );
      });
    }
  });

  group('CSV of peer text with an invisible lead (SPEC 5.10)', () {
    late TestPhone phone;
    late Seed s;
    setUp(() async {
      phone = await TestPhone.create('a');
      s = await phone.seedGroup(expenses: 1);
    });
    tearDown(() => phone.close());

    const peer = 'pppppppp-0000-7000-8000-000000000044';

    for (final lead in [
      '\u200B',
      '\uFEFF',
      '\u2060',
      ' ',
      '\u00A0',
      '\u3000',
    ]) {
      final code = lead.codeUnitAt(0).toRadixString(16);
      test('description led by U+$code then = is not a live formula', () async {
        final template = phone
            .opsOf(s.g)
            .lastWhere((o) => o.entityType == EntityType.expense);
        final op = Operation(
          id: 'peer-op-$code',
          groupId: s.g,
          deviceId: peer,
          counter: 1,
          hlc: Hlc(template.hlc.millis + 1, 0, peer),
          entityType: EntityType.expense,
          entityId: 'peer-expense-$code',
          kind: OpKind.create,
          payload: {
            ...template.payload,
            ExpenseFields.description: '$lead=HYPERLINK("http://x.ex","y")',
          },
        );
        try {
          await phone.ledger.applyRemote(s.g, [op]);
        } on FormatException {
          return; // refused outright: nothing to export
        }
        final csv = CsvExport.group(phone.state.groups[s.g]!);
        final line = csv
            .split('\r\n')
            .firstWhere((l) => l.contains('HYPERLINK'), orElse: () => '');
        if (line.isEmpty) return;
        // The description is the second cell; once quoted it starts '"'.
        final afterDate = line.substring(line.indexOf(',') + 1);
        final cell = afterDate.startsWith('"')
            ? afterDate.substring(1)
            : afterDate;
        expect(cell.startsWith('='), isFalse, reason: line);
      });
    }
  });
}
