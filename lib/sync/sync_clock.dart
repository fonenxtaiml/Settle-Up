/// Wall-clock source for the sync engine (test hook, SPEC 4.2). Used for
/// token windows, host expiry and record timestamps. Session timeouts use a
/// monotonic stopwatch instead.
abstract interface class SyncClock {
  DateTime now();
}

final class SystemSyncClock implements SyncClock {
  const SystemSyncClock();

  @override
  DateTime now() => DateTime.now();
}
