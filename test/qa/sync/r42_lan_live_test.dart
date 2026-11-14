// QA SYNC round 42, final regression sweep: a LIVE session over the real
// LanTransport on 127.0.0.1 (real TCP sockets and framing; mDNS faked).
// Pushes both ways while LIVE, then the Sync screen is left on both
// phones: records count each op once and the next sync is empty.
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
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';

import '../../sync/lan/support.dart';
import 'qa_phone.dart';

final class _LanPhone {
  _LanPhone(this.ledger, this.engine);

  static Future<_LanPhone> create(
    String letter,
    String name,
    FakeMdnsHub hub,
  ) async {
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds(letter);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: name,
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
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
    return _LanPhone(ledger, engine);
  }

  final Ledger ledger;
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
  late _LanPhone alex, priya;
  late GroupId g;
  late MemberId a, b;

  setUp(() async {
    hub = FakeMdnsHub();
    alex = await _LanPhone.create('a', "Alex's Pixel", hub);
    priya = await _LanPhone.create('b', "Priya's Pixel", hub);
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

  Future<void> expenses(_LanPhone p, int n, String tag) async {
    for (var i = 0; i < n; i++) {
      await p.ledger.addExpense(
        ExpenseDraft(
          groupId: g,
          description: '$tag$i',
          total: 100 + i,
          currency: 'INR',
          paidBy: SplitSpec.single(i.isEven ? a : b, 100 + i),
          owedBy: SplitSpec.equal([a, b]),
          category: 'food.dining',
          date: utcFromMillis(kBaseMs),
        ),
      );
    }
  }

  test('LIVE over TCP: 200 and 50 ops pushed both ways, counted once, '
      'the next sync is empty', () async {
    await expenses(alex, 3, 'S');
    await priya.engine.acceptInvite(
      await alex.engine.inviteLinkFor(g, includeHost: false),
    );
    final aBefore = (await alex.records()).length;
    final pBefore = (await priya.records()).length;
    alex.engine.liveMode = true;
    priya.engine.liveMode = true;
    final host = await alex.engine.startHosting();
    final live = await priya.engine
        .syncWithLink(host.connectLink)
        .timeout(const Duration(seconds: 10));
    final first = alex.ops;
    expect(live.receivedOps, first);

    await Future.wait([expenses(alex, 200, 'A'), expenses(priya, 50, 'P')]);
    expect(
      await waitFor(
        () => alex.ops == first + 250 && priya.ops == first + 250,
        timeout: const Duration(seconds: 20),
      ),
      isTrue,
      reason: 'live pushes over TCP: alex ${alex.ops}, priya ${priya.ops}',
    );
    expect(priya.canonical, alex.canonical);
    expect(
      await waitFor(
        () =>
            (alex.ledger.current.unsharedCounts[g] ?? 0) == 0 &&
            (priya.ledger.current.unsharedCounts[g] ?? 0) == 0,
      ),
      isTrue,
    );

    alex.engine.liveMode = false;
    priya.engine.liveMode = false;
    expect(
      await waitFor(
        () async =>
            (await alex.records()).length > aBefore &&
            (await priya.records()).length > pBefore,
        timeout: const Duration(seconds: 8),
      ),
      isTrue,
    );
    final ra = (await alex.records()).first;
    final rp = (await priya.records()).first;
    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect((ra.sentOps, ra.receivedOps), (first + 200, 50));
    expect((rp.sentOps, rp.receivedOps), (50, first + 200));

    await waitFor(() => alex.engine.status.session is! SessionActive);
    final s = await priya.engine
        .syncWithLink(host.connectLink)
        .timeout(const Duration(seconds: 10));
    expect((s.sentOps, s.receivedOps), (0, 0));
    expect(priya.canonical, alex.canonical);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
