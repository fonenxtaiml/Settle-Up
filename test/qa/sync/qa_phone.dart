// QA SYNC round 1: a simulated phone for multi-phone tests through the
// real DefaultSyncEngine. Real Ledger (MemoryOpStore or SqliteOpStore
// ':memory:'), real KvSettingsRepository, MemoryGroupKeyStore, real
// engine over MemoryTransports (lan, nearby, ble) on a shared hub, and a
// clock that can be skewed for both the HLC and the engine.
import 'dart:async';
import 'dart:typed_data';

import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

export '../../sync/support/harness.dart';
export '../../sync/support/phone.dart'
    show PhoneIds, SpyStore, deviceIdOf, kBaseMs;

/// Wall clock plus a fixed offset (a phone whose clock is wrong).
final class SkewedClock implements SyncClock {
  SkewedClock([this.offset = Duration.zero]);
  Duration offset;

  @override
  DateTime now() => DateTime.now().toUtc().add(offset);

  int nowMillis() => now().millisecondsSinceEpoch;
}

/// A clock frozen at [value] (tests move it by hand).
final class FixedClock implements SyncClock {
  FixedClock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
}

typedef QaSeed = ({GroupId g, MemberId a, MemberId b});

/// One phone.
final class QaPhone {
  QaPhone._(
    this.letter,
    this.opStore,
    this.ledger,
    this.spy,
    this.clock,
    this.transports,
    this.engine,
  );

  static Future<QaPhone> create(
    MemoryTransportHub hub,
    String letter,
    String deviceName, {
    String displayName = 'Alex',
    SyncClock? engineClock,
    SkewedClock? clock,
    List<TransportKind> kinds = const [TransportKind.lan, TransportKind.ble],
    Map<TransportKind, int> maxFrameBytes = const {TransportKind.ble: 16384},
    bool sqlite = false,
    bool spyStore = false,
    SessionTimings timings = fastTimings,
    Duration connectTimeout = const Duration(seconds: 2),
    Duration linkConnectTimeout = const Duration(seconds: 1),
    SyncTransport Function(MemoryTransport t)? wrap,
    String? deviceId,
  }) async {
    final skew = clock ?? SkewedClock();
    final OpStore opStore = sqlite
        ? SqliteOpStore(':memory:', nowMillis: skew.nowMillis)
        : MemoryOpStore();
    await opStore.open();
    final IdGenerator ids = deviceId == null
        ? PhoneIds(letter)
        : _FirstId(deviceId, PhoneIds(letter));
    final settings = await KvSettingsRepository.open(
      opStore,
      defaultDeviceName: deviceName,
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(
      displayName: displayName,
      homeCurrency: 'INR',
    );
    final ledger = await Ledger.open(
      store: opStore,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: skew.nowMillis,
    );
    final spy = SpyStore(ledger);
    final transports = <TransportKind, MemoryTransport>{
      for (final k in kinds)
        k: MemoryTransport(
          hub,
          kind: k,
          address: '$letter-${k.name}',
          maxFrameBytes: maxFrameBytes[k] ?? (1 << 20),
        ),
    };
    final engine = DefaultSyncEngine(
      store: spyStore ? spy : ledger,
      transports: [
        for (final t in transports.values) wrap == null ? t : wrap(t),
      ],
      clock: engineClock ?? skew,
      timings: timings,
      connectTimeout: connectTimeout,
      linkConnectTimeout: linkConnectTimeout,
    );
    return QaPhone._(letter, opStore, ledger, spy, skew, transports, engine);
  }

  final String letter;
  final OpStore opStore;
  final Ledger ledger;
  final SpyStore spy;
  final SkewedClock clock;
  final Map<TransportKind, MemoryTransport> transports;
  final DefaultSyncEngine engine;

  MemoryTransport get lan => transports[TransportKind.lan]!;
  MemoryTransport get ble => transports[TransportKind.ble]!;
  MemoryTransport get nearby => transports[TransportKind.nearby]!;

  DeviceId get deviceId => ledger.localDeviceId;
  String get deviceName => ledger.localDeviceName;
  LedgerSnapshot get snapshot => ledger.current;
  LedgerState get state => ledger.current.state;
  Map<String, Object?> get canonical => state.toCanonicalJson();

  List<Operation> opsOf(GroupId g) => [
    for (final op in ledger.current.ops)
      if (op.groupId == g) op,
  ];
  int opCount(GroupId g) => opsOf(g).length;
  int get totalOps => ledger.current.ops.length;

  Future<List<SyncRecord>> records() => ledger.watchSyncRecords().first;

  Future<void> dispose() async {
    try {
      await engine.dispose();
    } catch (_) {}
    try {
      await ledger.close();
    } catch (_) {}
    try {
      await opStore.close();
    } catch (_) {}
  }

  /// Discovers [other] once it is seen on [transports] transports.
  Future<NearbyPeer> find(
    QaPhone other, {
    int transports = 1,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!engine.status.discovering) await engine.startDiscovery();
    bool match(NearbyPeer p) =>
        p.name == other.deviceName && p.transports.length >= transports;
    final list = await engine
        .watchNearby()
        .firstWhere((l) => l.any(match))
        .timeout(timeout);
    return list.firstWhere(match);
  }

  /// Creates a group with the owner and [others] (default "Priya"), then
  /// [expenses] expenses.
  Future<QaSeed> seedGroup({
    int expenses = 3,
    String name = 'Goa trip',
    List<String> others = const ['Priya'],
  }) async {
    final g = await ledger.createGroup(
      NewGroup(
        name: name,
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: others,
      ),
    );
    final members = state.groups[g]!.members.values;
    final b = members.firstWhere((m) => m.displayName == others.first).id;
    final a = members
        .firstWhere(
          (m) => m.deviceId == deviceId,
          orElse: () => members.firstWhere((m) => m.id != b),
        )
        .id;
    for (var i = 0; i < expenses; i++) {
      await addExpense(
        g,
        payer: a,
        owers: [a, b],
        total: 1000 + i,
        description: 'Item $i',
      );
    }
    return (g: g, a: a, b: b);
  }

  Future<void> join(QaPhone owner, GroupId g) async {
    await ledger.registerJoinedGroup(
      g,
      (await owner.ledger.groupKeys())[g]!,
      'Goa trip',
    );
  }

  Future<ExpenseId> addExpense(
    GroupId g, {
    required MemberId payer,
    required List<MemberId> owers,
    int total = 6000,
    String description = 'Dinner',
  }) => ledger.addExpense(
    ExpenseDraft(
      groupId: g,
      description: description,
      total: total,
      currency: 'INR',
      paidBy: SplitSpec.single(payer, total),
      owedBy: SplitSpec.equal(owers),
      category: 'food.dining',
      date: utcFromMillis(kBaseMs),
    ),
  );

  Future<void> addExpenses(QaSeed s, int count, {int base = 100}) async {
    for (var i = 0; i < count; i++) {
      await addExpense(
        s.g,
        payer: i.isEven ? s.a : s.b,
        owers: [s.a, s.b],
        total: base + i,
        description: 'E$i',
      );
    }
  }

  Future<void> edit(ExpenseId e, {String? description, int? total}) {
    final x = state.expense(e)!;
    final t = total ?? x.money.total;
    final payer = x.money.paidBy.values.keys.first;
    return ledger.updateExpense(
      e,
      ExpenseDraft(
        groupId: x.groupId,
        description: description ?? x.description,
        total: t,
        currency: x.money.currency,
        paidBy: total == null ? x.money.paidBy : SplitSpec.single(payer, t),
        owedBy: total == null
            ? x.money.owedBy
            : SplitSpec.equal(x.money.owedBy.values.keys),
        category: x.category,
        date: x.date,
        notes: x.notes,
      ),
    );
  }
}

/// Every phone's canonical state equals the first one's.
bool allEqual(List<QaPhone> phones) {
  final first = phones.first.canonical.toString();
  return phones.every((p) => p.canonical.toString() == first);
}

/// Waits for [condition] (polling).
Future<bool> waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

/// Syncs [from] with [to] via the connect link of [to]'s hosting.
Future<SyncSummary> syncByLink(QaPhone from, QaPhone to) async {
  final host = await to.engine.startHosting();
  final summary = await from.engine.syncWithLink(host.connectLink);
  // Let the responder finish recording before the next session.
  await waitFor(() => to.engine.status.session is! SessionActive);
  return summary;
}

/// Delegates to a [MemoryTransport]; [cut] turns every channel this side
/// opened into a black hole (no frames either way, no close): the peer
/// sees a half-open connection, like a phone that walked out of range.
final class CuttableTransport implements SyncTransport {
  CuttableTransport(this.inner);
  final MemoryTransport inner;
  final List<CuttableChannel> channels = [];

  void cut() {
    for (final c in channels) {
      c.cut = true;
    }
  }

  @override
  TransportKind get kind => inner.kind;
  @override
  Future<TransportAvailability> availability() => inner.availability();
  @override
  Future<TransportAvailability> requestPermissions() =>
      inner.requestPermissions();
  @override
  Future<void> startAdvertising(AdvertiseInfo info) =>
      inner.startAdvertising(info);
  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();
  @override
  Stream<FrameChannel> get inbound => inner.inbound;
  @override
  Stream<DiscoveredPeer> discover() => inner.discover();
  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final c = CuttableChannel(await inner.connect(peer, timeout: timeout));
    channels.add(c);
    return c;
  }

  @override
  Future<void> dispose() => inner.dispose();
}

final class CuttableChannel implements FrameChannel {
  CuttableChannel(this.inner);
  final FrameChannel inner;
  bool cut = false;
  final StreamController<Uint8List> _dead = StreamController();

  @override
  TransportKind get kind => inner.kind;
  @override
  String get peerAddress => inner.peerAddress;
  @override
  int get maxFrameBytes => inner.maxFrameBytes;
  @override
  Stream<Uint8List> get frames => inner.frames.where((_) => !cut);
  @override
  Future<void> send(Uint8List frame) async {
    if (cut) return;
    await inner.send(frame);
  }

  @override
  Future<void> close() async {
    if (cut) {
      // The peer never hears about it; end our own side locally.
      unawaited(_dead.close());
      return;
    }
    await inner.close();
  }
}

/// Returns [first] once (the device id), then delegates.
final class _FirstId implements IdGenerator {
  _FirstId(this.first, this.rest);
  final String first;
  final IdGenerator rest;
  bool _used = false;

  @override
  String newId() {
    if (_used) return rest.newId();
    _used = true;
    rest.newId(); // keep the rest of the sequence unchanged
    return first;
  }
}
