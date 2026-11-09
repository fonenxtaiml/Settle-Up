// Demo data: the Goa trip / Flat 4B / Cabin weekend world of the reference
// renders (docs/design/point-to-point/). Every balance is computed by the
// real core from real ops, so the numbers stay consistent:
//   Home: you're owed +₹4,250 overall; Goa trip −₹840, Flat 4B +₹5,090,
//   Cabin weekend settled; Priya owes you +₹1,200.
//   Goa trip suggested payments: you pay Priya ₹840, Kabir pays Ravi
//   ₹6,150, Isha pays Ravi ₹4,010.
//   Sync: 3 changes to share (2 expenses, 1 payment), last synced with
//   Priya's Pixel 8 yesterday at 9:12 pm.
import '../../core/ids.dart';
import '../../core/ledger_state.dart';
import '../../core/models.dart';
import '../../data/repositories.dart';
import '../../sync/sync_engine.dart';
import 'fake_ledger.dart';
import 'fake_settings.dart';
import 'fake_sync_engine.dart';

/// Fixed ids so tests and goldens can point at demo people and phones.
abstract final class DemoIds {
  static const me = '00000000-0000-7000-8000-00000000a000';
  static const priya = '00000000-0000-7000-8000-00000000a001';
  static const ravi = '00000000-0000-7000-8000-00000000a002';
  static const kabir = '00000000-0000-7000-8000-00000000a003';
  static const isha = '00000000-0000-7000-8000-00000000a004';
  static const neha = '00000000-0000-7000-8000-00000000a005';
  static const rohan = '00000000-0000-7000-8000-00000000a006';
  static const aditi = '00000000-0000-7000-8000-00000000a007';

  static const thisPhone = '00000000-0000-7000-8000-00000000d000';
  static const priyaPhone = '00000000-0000-7000-8000-00000000d001';
  static const raviPhone = '00000000-0000-7000-8000-00000000d002';
  static const kabirPhone = '00000000-0000-7000-8000-00000000d003';
}

const Profile demoProfile = Profile(
  personId: DemoIds.me,
  displayName: 'Arjun Mehta',
  homeCurrency: 'INR',
);

/// Settings for the demo: onboarded as Arjun Mehta on "Arjun's Pixel 8".
FakeSettingsRepository demoSettings({bool onboarded = true}) =>
    FakeSettingsRepository(
      profile: onboarded ? demoProfile : null,
      device: const DeviceIdentity(
        deviceId: DemoIds.thisPhone,
        deviceName: "Arjun's Pixel 8",
      ),
    );

/// Group ids of the seeded world.
final class DemoGroups {
  const DemoGroups({
    required this.goa,
    required this.flat,
    required this.cabin,
  });
  final GroupId goa;
  final GroupId flat;
  final GroupId cabin;
}

/// Fills [ledger] (and [engine]'s history and nearby phones) with the demo
/// world as of [now] (default: the current time; goldens pass the
/// reference date, Sun 9 Nov 2026 10:00).
/// The settings behind [ledger] must already hold [demoProfile].
Future<DemoGroups> seedDemoData(
  FakeLedgerRepository ledger, {
  FakeSyncEngine? engine,
  DateTime? now,
}) async {
  final n = now ?? DateTime.now();
  DateTime daysAgo(int d, int h, [int m = 0]) =>
      DateTime(n.year, n.month, n.day - d, h, m);
  late DemoGroups groups;

  await ledger.batch(() async {
    // ------------------------------------------------------- Cabin weekend
    final cabin = await ledger.actAt(
      daysAgo(23, 18),
      () => ledger.createGroup(
        const NewGroup(
          name: 'Cabin weekend',
          type: GroupType.trip,
          currency: 'INR',
          simplifyDebts: true,
          existingPeople: [
            (personId: DemoIds.kabir, displayName: 'Kabir Singh'),
            (personId: DemoIds.isha, displayName: 'Isha Nair'),
            (personId: DemoIds.aditi, displayName: 'Aditi Rao'),
          ],
        ),
      ),
    );
    MemberId m(GroupId g, PersonId p) =>
        ledger.current.state.groups[g]!.memberForPerson(p)!.id;
    GroupState gs(GroupId g) => ledger.current.state.groups[g]!;

    await ledger.actAt(
      daysAgo(22, 11),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: cabin,
          description: 'Cabin booking',
          total: 1200000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(cabin, DemoIds.me), 1200000),
          owedBy: SplitSpec.equal(gs(cabin).activeMembers.map((x) => x.id)),
          category: 'transport.hotel',
          date: daysAgo(22, 11),
        ),
      ),
    );
    for (final (i, p) in [DemoIds.kabir, DemoIds.isha, DemoIds.aditi].indexed) {
      await ledger.actAt(
        daysAgo(20, 9 + i),
        () => ledger.recordPayment(
          PaymentDraft(
            groupId: cabin,
            from: m(cabin, p),
            to: m(cabin, DemoIds.me),
            amount: 300000,
            currency: 'INR',
            method: PaymentMethod.upi,
            date: daysAgo(20, 9 + i),
          ),
        ),
      );
    }

    // ------------------------------------------------------------- Flat 4B
    final flat = await ledger.actAt(
      daysAgo(18, 20),
      () => ledger.createGroup(
        const NewGroup(
          name: 'Flat 4B',
          type: GroupType.home,
          currency: 'INR',
          simplifyDebts: true,
          existingPeople: [
            (personId: DemoIds.priya, displayName: 'Priya Sharma'),
            (personId: DemoIds.rohan, displayName: 'Rohan Das'),
          ],
        ),
      ),
    );
    await ledger.actAs(
      device: DemoIds.priyaPhone,
      person: DemoIds.priya,
      at: daysAgo(18, 21),
      body: () => ledger.claimMember(flat, m(flat, DemoIds.priya)),
    );
    await ledger.actAt(
      daysAgo(7, 19),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: flat,
          description: 'Wi-Fi recharge',
          total: 135000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(flat, DemoIds.me), 135000),
          owedBy: SplitSpec(SplitMethod.exact, {
            m(flat, DemoIds.me): 40000,
            m(flat, DemoIds.rohan): 95000,
          }),
          category: 'utilities.internet',
          date: daysAgo(7, 19),
        ),
      ),
    );
    await ledger.actAt(
      daysAgo(6, 9),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: flat,
          description: 'Electricity bill',
          total: 360000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(flat, DemoIds.me), 360000),
          owedBy: SplitSpec.equal(gs(flat).activeMembers.map((x) => x.id)),
          category: 'utilities.electricity',
          date: daysAgo(6, 9),
        ),
      ),
    );
    await ledger.actAs(
      device: DemoIds.priyaPhone,
      person: DemoIds.priya,
      at: daysAgo(2, 8),
      body: () => ledger.addExpense(
        ExpenseDraft(
          groupId: flat,
          description: 'Milk and bread',
          total: 18000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(flat, DemoIds.priya), 18000),
          owedBy: SplitSpec(SplitMethod.exact, {
            m(flat, DemoIds.me): 6000,
            m(flat, DemoIds.priya): 12000,
          }),
          category: 'food.groceries',
          date: daysAgo(2, 8),
        ),
      ),
    );

    // ------------------------------------------------------------ Goa trip
    final goa = await ledger.actAt(
      daysAgo(8, 10),
      () => ledger.createGroup(
        const NewGroup(
          name: 'Goa trip',
          type: GroupType.trip,
          currency: 'INR',
          simplifyDebts: true,
          existingPeople: [
            (personId: DemoIds.priya, displayName: 'Priya Sharma'),
            (personId: DemoIds.ravi, displayName: 'Ravi Kumar'),
            (personId: DemoIds.kabir, displayName: 'Kabir Singh'),
            (personId: DemoIds.isha, displayName: 'Isha Nair'),
            (personId: DemoIds.neha, displayName: 'Neha Joshi'),
          ],
        ),
      ),
    );
    for (final (device, person, h) in [
      (DemoIds.priyaPhone, DemoIds.priya, 11),
      (DemoIds.raviPhone, DemoIds.ravi, 12),
      (DemoIds.kabirPhone, DemoIds.kabir, 13),
    ]) {
      await ledger.actAs(
        device: device,
        person: person,
        at: daysAgo(8, h),
        body: () => ledger.claimMember(goa, m(goa, person)),
      );
    }
    final everyone = gs(goa).activeMembers.map((x) => x.id).toList();
    // Advances towards the hotel deposit, and my share of the boat trip.
    for (final (from, to, amount, device, person) in [
      (DemoIds.priya, DemoIds.ravi, 654000, DemoIds.priyaPhone, DemoIds.priya),
      (DemoIds.neha, DemoIds.ravi, 560000, DemoIds.raviPhone, DemoIds.ravi),
      (DemoIds.isha, DemoIds.ravi, 99000, DemoIds.raviPhone, DemoIds.ravi),
      (DemoIds.kabir, DemoIds.ravi, 61000, DemoIds.kabirPhone, DemoIds.kabir),
      (DemoIds.me, DemoIds.kabir, 176000, DemoIds.kabirPhone, DemoIds.kabir),
    ]) {
      await ledger.actAs(
        device: device,
        person: person,
        at: daysAgo(3, 18, amount % 60),
        body: () => ledger.recordPayment(
          PaymentDraft(
            groupId: goa,
            from: m(goa, from),
            to: m(goa, to),
            amount: amount,
            currency: 'INR',
            method: PaymentMethod.upi,
            date: daysAgo(3, 18, amount % 60),
          ),
        ),
      );
    }
    await ledger.actAs(
      device: DemoIds.raviPhone,
      person: DemoIds.ravi,
      at: daysAgo(1, 12),
      body: () => ledger.addExpense(
        ExpenseDraft(
          groupId: goa,
          description: 'Hotel deposit',
          total: 3000000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(goa, DemoIds.ravi), 3000000),
          owedBy: SplitSpec.equal(everyone),
          category: 'transport.hotel',
          date: daysAgo(1, 12),
        ),
      ),
    );
    await ledger.actAt(
      daysAgo(1, 21),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: goa,
          description: "Dinner at Britto's",
          total: 600000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(goa, DemoIds.me), 600000),
          owedBy: SplitSpec(SplitMethod.exact, {
            m(goa, DemoIds.me): 100000,
            m(goa, DemoIds.priya): 250000,
            m(goa, DemoIds.ravi): 250000,
          }),
          category: 'food.dining',
          date: daysAgo(1, 21),
          notes: 'Ravi and Priya had the lobster.',
        ),
      ),
    );

    // Everything up to here reached Priya's phone last night at 9:12 pm.
    ledger.markAllShared();

    // This morning, on this phone: 2 expenses and 1 payment, not yet shared.
    await ledger.actAt(
      daysAgo(0, 8, 40),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: flat,
          description: 'Groceries',
          total: 270000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(flat, DemoIds.me), 270000),
          owedBy: SplitSpec.equal(gs(flat).activeMembers.map((x) => x.id)),
          category: 'food.groceries',
          date: daysAgo(0, 8, 40),
        ),
      ),
    );
    await ledger.actAt(
      daysAgo(0, 9, 10),
      () => ledger.recordPayment(
        PaymentDraft(
          groupId: goa,
          from: m(goa, DemoIds.ravi),
          to: m(goa, DemoIds.me),
          amount: 200000,
          currency: 'INR',
          method: PaymentMethod.upi,
          date: daysAgo(0, 9, 10),
        ),
      ),
    );
    await ledger.actAt(
      daysAgo(0, 9, 30),
      () => ledger.addExpense(
        ExpenseDraft(
          groupId: goa,
          description: 'Scooter rental',
          total: 240000,
          currency: 'INR',
          paidBy: SplitSpec.single(m(goa, DemoIds.priya), 240000),
          owedBy: SplitSpec.equal([
            m(goa, DemoIds.me),
            m(goa, DemoIds.priya),
            m(goa, DemoIds.ravi),
            m(goa, DemoIds.neha),
          ]),
          category: 'transport',
          date: daysAgo(0, 9, 30),
        ),
      ),
    );
    groups = DemoGroups(goa: goa, flat: flat, cabin: cabin);
  });

  if (engine != null) {
    final last = DateTime(n.year, n.month, n.day - 1, 21, 12);
    engine.addHistory(
      SyncRecord(
        id: 'sync-demo-1',
        peerDeviceId: DemoIds.priyaPhone,
        peerName: "Priya's Pixel 8",
        transport: TransportKind.lan,
        startedAt: last.subtract(const Duration(seconds: 4)),
        endedAt: last,
        sentOps: 6,
        receivedOps: 9,
        groupIds: [groups.goa, groups.flat],
        outcome: SyncOutcome.completed,
      ),
    );
    engine.peersToFind
      ..clear()
      ..addAll(demoPeers(groups));
  }
  return groups;
}

/// The three phones of render 5.
List<NearbyPeer> demoPeers(DemoGroups g) => [
  NearbyPeer(
    key: 'peer-priya',
    name: "Priya's Pixel 8",
    deviceIdPrefix: DemoIds.priyaPhone.substring(0, 8),
    transports: const {TransportKind.lan, TransportKind.ble},
    sharedGroupIds: [g.goa],
  ),
  NearbyPeer(
    key: 'peer-ravi',
    name: "Ravi's iPhone",
    deviceIdPrefix: DemoIds.raviPhone.substring(0, 8),
    transports: const {TransportKind.ble},
    sharedGroupIds: [g.goa],
  ),
  const NearbyPeer(
    key: 'peer-unknown',
    name: 'Unknown phone',
    transports: {TransportKind.ble},
    sharedGroupIds: [],
  ),
];

/// One call for a fully seeded fake world (bootstrap and tests).
Future<
  ({
    FakeSettingsRepository settings,
    FakeLedgerRepository ledger,
    FakeSyncEngine engine,
    DemoGroups groups,
  })
>
createDemoWorld({
  DateTime? now,
  IdGenerator ids = const UuidV7Generator(),
  Duration syncStep = const Duration(milliseconds: 450),
}) async {
  final clock = now == null ? DateTime.now : () => now;
  final settings = demoSettings();
  final ledger = FakeLedgerRepository(
    settings: settings,
    ids: ids,
    nowMillis: () => clock().millisecondsSinceEpoch,
  );
  final engine = FakeSyncEngine(
    ledger: ledger,
    settings: settings,
    now: clock,
    step: syncStep,
  );
  final groups = await seedDemoData(ledger, engine: engine, now: clock());
  return (settings: settings, ledger: ledger, engine: engine, groups: groups);
}
