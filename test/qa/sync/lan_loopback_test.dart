// QA SYNC-R1: the same multi-phone scenarios over the real LanTransport on
// 127.0.0.1 (real TCP sockets and framing; mDNS faked).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';

import '../../sync/lan/support.dart';
import 'qa_phone.dart';

final class LanQaPhone {
  LanQaPhone._(this.ledger, this.lan, this.engine);

  static Future<LanQaPhone> create(
    String letter,
    String name,
    FakeMdnsHub hub, {
    String displayName = 'Alex',
  }) async {
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds(letter);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: name,
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(
      displayName: displayName,
      homeCurrency: 'INR',
    );
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
    );
    final lan = LanTransport(
      port: 0,
      mdns: FakeMdns(hub),
      network: FakeLanNetwork(),
      bindAddress: InternetAddress.loopbackIPv4,
      rediscoverInterval: const Duration(milliseconds: 150),
      probeInterval: const Duration(milliseconds: 150),
      firstFrameTimeout: const Duration(seconds: 2),
    );
    final engine = DefaultSyncEngine(
      store: ledger,
      transports: [lan],
      timings: fastTimings,
      linkConnectTimeout: const Duration(seconds: 1),
    );
    return LanQaPhone._(ledger, lan, engine);
  }

  final Ledger ledger;
  final LanTransport lan;
  final DefaultSyncEngine engine;

  Map<String, Object?> get canonical => ledger.current.state.toCanonicalJson();
  int get ops => ledger.current.ops.length;
  Future<List<SyncRecord>> records() => ledger.watchSyncRecords().first;

  Future<void> dispose() async {
    await engine.dispose();
    await ledger.close();
  }
}

void main() {
  late FakeMdnsHub hub;
  late LanQaPhone alex, priya;
  late GroupId g;
  late MemberId a, b;

  setUp(() async {
    hub = FakeMdnsHub();
    alex = await LanQaPhone.create('a', "Alex's Pixel", hub);
    priya = await LanQaPhone.create(
      'b',
      "Priya's Pixel",
      hub,
      displayName: 'Priya',
    );
    g = await alex.ledger.createGroup(
      const NewGroup(
        name: 'Goa trip',
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: ['Priya'],
      ),
    );
    final members = alex.ledger.current.state.groups[g]!.members.values;
    b = members.firstWhere((m) => m.displayName == 'Priya').id;
    a = members.firstWhere((m) => m.id != b).id;
  });

  tearDown(() async {
    await alex.dispose();
    await priya.dispose();
  });

  Future<void> expenses(LanQaPhone p, int n, {int base = 100}) async {
    for (var i = 0; i < n; i++) {
      await p.ledger.addExpense(
        ExpenseDraft(
          groupId: g,
          description: 'E$i',
          total: base + i,
          currency: 'INR',
          paidBy: SplitSpec.single(i.isEven ? a : b, base + i),
          owedBy: SplitSpec.equal([a, b]),
          category: 'food.dining',
          date: utcFromMillis(kBaseMs),
        ),
      );
    }
  }

  test(
    'invite with h=127.0.0.1:port -> join -> first sync -> claim back',
    () async {
      await expenses(alex, 5);
      final link = await alex.engine.inviteLinkFor(g);
      final host = InviteLink.tryParse(link)!.host!;
      expect(host, startsWith('127.0.0.1:'));
      final join = await priya.engine.acceptInvite(link);
      expect(join.firstSync?.receivedOps, alex.ops);
      expect(priya.canonical, alex.canonical);

      await priya.ledger.claimMember(g, b);
      final s = await priya.engine.syncWithLink(link);
      expect(s.sentOps, 1);
      expect(
        alex.ledger.current.state.groups[g]!.members[b]!.deviceId,
        priya.ledger.localDeviceId,
      );
    },
  );

  test('concurrent offline edits then 5 repeated syncs over TCP', () async {
    await expenses(alex, 4);
    await priya.engine.acceptInvite(await alex.engine.inviteLinkFor(g));
    final e = alex.ledger.current.state.groups[g]!.expenses.keys.first;
    final x = alex.ledger.current.state.expense(e)!;
    ExpenseDraft draft(String d) => ExpenseDraft(
      groupId: g,
      description: d,
      total: x.money.total,
      currency: 'INR',
      paidBy: x.money.paidBy,
      owedBy: x.money.owedBy,
      category: x.category,
      date: x.date,
    );
    await alex.ledger.updateExpense(e, draft('Alex'));
    await priya.ledger.updateExpense(e, draft('Priya'));
    await priya.ledger.addMember(g, displayName: 'Bob');
    await alex.ledger.addMember(g, displayName: 'Bob');
    final host = await alex.engine.startHosting();
    await priya.engine.syncWithLink(host.connectLink);
    expect(priya.canonical, alex.canonical);
    final ops = alex.ops;
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final s = await priya.engine.syncWithLink(host.connectLink);
      expect((s.sentOps, s.receivedOps), (0, 0));
    }
    expect(alex.ops, ops);
    expect(priya.canonical, alex.canonical);
    expect((await priya.records()).length, greaterThanOrEqualTo(6));
  });

  test('2,000 ops over TCP in 1 MiB frames', () async {
    await priya.engine.acceptInvite(
      await alex.engine.inviteLinkFor(g, includeHost: false),
    );
    await expenses(alex, 2000);
    final host = await alex.engine.startHosting();
    final sw = Stopwatch()..start();
    final s = await priya.engine
        .syncWithLink(host.connectLink)
        .timeout(const Duration(minutes: 2));
    expect(s.receivedOps, alex.ops);
    expect(priya.canonical, alex.canonical);
    // ignore: avoid_print
    print('QA LAN: ${alex.ops} ops in ${sw.elapsedMilliseconds} ms');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'host goes away mid-transfer: partial, no dupes, resume completes',
    () async {
      await priya.engine.acceptInvite(
        await alex.engine.inviteLinkFor(g, includeHost: false),
      );
      await expenses(alex, 1500);
      var host = await alex.engine.startHosting();
      final run = priya.engine
          .syncWithLink(host.connectLink)
          .then<Object?>((s) => s, onError: (Object e) => e);
      // Kill the host's whole session once some ops have arrived.
      await waitFor(() => priya.ops > 2, timeout: const Duration(seconds: 10));
      await alex.engine.cancel();
      final r = await run;
      if (r is SyncException) {
        expect(
          r.failure,
          anyOf(SyncFailure.cancelled, SyncFailure.connectionLost),
        );
      }
      final got = priya.ops;
      expect(got, lessThanOrEqualTo(alex.ops));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      host = await alex.engine.startHosting();
      final again = await priya.engine.syncWithLink(host.connectLink);
      expect(again.receivedOps, alex.ops - got);
      expect(priya.canonical, alex.canonical);
    },
  );

  test('connect link with a refused port and a dead host first', () async {
    await priya.engine.acceptInvite(
      await alex.engine.inviteLinkFor(g, includeHost: false),
    );
    final host = await alex.engine.startHosting();
    // A free port that nobody listens on: refused at once.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    final real = ConnectLink.tryParse(host.connectLink)!;
    final link = ConnectLink(
      hosts: ['127.0.0.1:$closedPort', ...real.hosts],
      deviceId: real.deviceId,
      deviceName: real.deviceName,
    ).encode();
    final s = await priya.engine.syncWithLink(link);
    expect(s.receivedOps, alex.ops);

    final dead = ConnectLink(
      hosts: ['127.0.0.1:$closedPort'],
      deviceId: real.deviceId,
      deviceName: real.deviceName,
    ).encode();
    await expectLater(
      priya.engine.syncWithLink(dead),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.peerUnreachable,
        ),
      ),
    );
  });

  test(
    'hosting expiry closes the server but not the running session',
    () async {
      await priya.engine.acceptInvite(
        await alex.engine.inviteLinkFor(g, includeHost: false),
      );
      await expenses(alex, 1500);
      await alex.engine.stopHosting();
      final host = await alex.engine.startHosting(
        duration: const Duration(milliseconds: 100),
      );
      final s = await priya.engine.syncWithLink(host.connectLink);
      expect(s.receivedOps, alex.ops);
      expect(alex.engine.status.host, isNull);
      await expectLater(
        priya.engine.syncWithLink(host.connectLink),
        throwsA(isA<SyncException>()),
      );
    },
  );
}
