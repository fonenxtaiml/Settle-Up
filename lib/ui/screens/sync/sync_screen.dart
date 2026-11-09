// Sync tab (render 5): what is waiting to be shared, this phone -> nearby
// phones, "Make this phone visible" with its QR and address, Scan a QR, and
// the phones found nearby with Sync or Pair.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models.dart';
import '../../../core/ops.dart';
import '../../../data/repositories.dart';
import '../../../sync/sync_engine.dart';
import '../../../sync/transport/transport.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import 'radios.dart';

/// "yesterday at 9:12 pm", "today at 8:05 am", "Sat, 1 Nov at 6:40 pm".
String whenLabel(DateTime at, DateTime now) {
  final clock = DateLabels.clock12(at);
  final days = DateLabels.daysBetween(at, now);
  if (days == 0) return S.todayAt(clock);
  if (days == 1) return S.yesterdayAt(clock);
  return S.onDateAt(DateLabels.dayHeader(at, now: now), clock);
}

/// "2 expenses and 1 payment" from the unshared ops of [snap].
String pendingWhat(LedgerSnapshot snap) {
  var expenses = 0;
  var payments = 0;
  var other = 0;
  for (final op in snap.ops) {
    if (!snap.unsharedOpIds.contains(op.id)) continue;
    if (op.entityType == EntityType.expense) {
      final e = snap.state.groups[op.groupId]?.expenses[op.entityId];
      if (e?.isPayment ?? false) {
        payments++;
      } else {
        expenses++;
      }
    } else {
      other++;
    }
  }
  final text = S.pendingBreakdown(expenses, payments, other);
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// Phone icon from the name a peer advertises.
NearbyPhoneKind phoneKindOf(NearbyPeer p) {
  if (!p.sharesGroups) return NearbyPhoneKind.unknown;
  return p.name.toLowerCase().contains('iphone')
      ? NearbyPhoneKind.iphone
      : NearbyPhoneKind.android;
}

/// Starts a session with [peer] and opens the progress screen.
void startSyncWith(BuildContext context, WidgetRef ref, NearbyPeer peer) {
  if (!peer.sharesGroups) {
    showSnack(
      context,
      S.pairHint,
      actionLabel: S.scanQr,
      onAction: () {
        context.push(Routes.syncScan);
      },
    );
    return;
  }
  final engine = ref.read(syncEngineProvider);
  unawaited(engine.syncWith(peer).then<void>((_) {}, onError: (Object _) {}));
  context.push(Routes.syncSession);
}

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen>
    with WidgetsBindingObserver {
  late final _engine = ref.read(syncEngineProvider);

  /// What each transport can do now; empty until first checked.
  Map<TransportKind, TransportAvailability> _radios = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ask for Bluetooth / Nearby first (SPEC 8.10): without the grant the
    // engine skips both transports.
    unawaited(_discover());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_engine.stopDiscovery().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the settings page: check again, and look again if a
    // transport has just become ready.
    if (state == AppLifecycleState.resumed) unawaited(_recheck());
  }

  Future<void> _recheck() async {
    Map<TransportKind, TransportAvailability> now;
    try {
      now = await _engine.availability();
    } on Object catch (_) {
      return;
    }
    if (!mounted) return;
    final gained = now.entries.any(
      (e) =>
          e.value == TransportAvailability.ready &&
          _radios[e.key] != TransportAvailability.ready,
    );
    setState(() => _radios = now);
    if (gained) {
      unawaited(_engine.startDiscovery().catchError((Object _) {}));
    }
  }

  Future<void> _prepare() async {
    final r = await prepareRadios(_engine);
    if (mounted) setState(() => _radios = r);
  }

  Future<void> _discover() async {
    await _prepare();
    if (!mounted) return;
    await _engine.startDiscovery().catchError((Object _) {});
  }

  Future<void> _toggleVisible(bool on) async {
    if (on) await _prepare();
    if (!mounted) return;
    await runGuarded(context, () async {
      if (on) {
        await _engine.startHosting();
      } else {
        await _engine.stopHosting();
      }
    });
  }

  void _help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(S.howSyncWorks),
      content: const Text(S.howSyncWorksBody),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(S.gotIt),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final status = ref.watch(syncStatusProvider).value ?? SyncStatus.idle;
    final snap = ref.watch(ledgerProvider).value;
    final history = ref.watch(syncHistoryProvider).value ?? const [];
    final peers = ref.watch(nearbyPeersProvider).value ?? const [];
    final now = ref.watch(clockProvider)();
    final pending = snap?.totalUnshared ?? 0;
    final done = history.where((r) => r.outcome != SyncOutcome.failed);
    final last = done.isEmpty ? null : done.first;
    final session = status.session;

    final groupNames = {
      for (final g in snap?.state.visibleGroups ?? const <Never>[])
        g.groupId: g.group!.name,
    };

    final headline = pending > 0
        ? S.changesToShare(pending)
        : S.everythingShared;
    final String body;
    if (pending > 0 && snap != null) {
      final what = pendingWhat(snap);
      body = last == null
          ? S.sinceNever(what)
          : S.sinceLastSync(what, last.peerName, whenLabel(last.endedAt, now));
    } else {
      body = last == null
          ? S.neverSyncedBody
          : S.lastSyncedWith(last.peerName, whenLabel(last.endedAt, now));
    }

    return Scaffold(
      appBar: screenAppBar(
        title: const Text(S.syncTitle),
        actions: [
          IconButton(
            onPressed: _help,
            tooltip: S.howSyncWorks,
            icon: const Icon(Icons.help_outline_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          textGutter(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: theme.textTheme.headlineSmall),
                const SizedBox(height: Space.xs),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
                ),
                const SizedBox(height: Space.md),
                SyncTether(
                  active: session is SessionActive,
                  connected: session is SessionCompleted,
                ),
              ],
            ),
          ),
          if (session is! SessionIdle) ...[
            const SizedBox(height: 14),
            gutter(_SessionStrip(session: session)),
          ],
          if (radioIssues(_radios).isNotEmpty) ...[
            const SizedBox(height: 14),
            gutter(
              RadioIssuesCard(
                issues: radioIssues(_radios),
                onAllow: () => unawaited(_discover()),
              ),
            ),
          ],
          const SizedBox(height: 14),
          gutter(
            _HostCard(host: status.host, onVisibleChanged: _toggleVisible),
          ),
          const SizedBox(height: Space.md),
          gutter(
            FilledButton.tonalIcon(
              onPressed: () => context.push(Routes.syncScan),
              style: KitButtonStyles.block.copyWith(
                minimumSize: const WidgetStatePropertyAll(
                  Size.fromHeight(Sizes.button),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: const Text(S.scanQr),
            ),
          ),
          gutter(
            SectionHeading(
              S.nearbyPhones,
              action: status.discovering
                  ? const LookingIndicator(label: S.looking)
                  : TextLink(
                      S.lookAgain,
                      onPressed: () => unawaited(_discover()),
                    ),
            ),
          ),
          if (peers.isEmpty)
            gutter(
              const ListSection(
                children: [
                  KitListRow(
                    title: S.noneNearbyHeadline,
                    subtitle: S.noneNearbyBody,
                  ),
                ],
              ),
            )
          else
            gutter(
              ListSection(
                children: [
                  for (final p in peers)
                    NearbyPhoneRow(
                      name: p.name,
                      subtitle: [
                        if (p.transports.contains(TransportKind.lan))
                          S.wifi
                        else
                          S.bluetooth,
                        S.sharesGroups([
                          for (final id in p.sharedGroupIds) ?groupNames[id],
                        ]),
                      ].join(', '),
                      kind: phoneKindOf(p),
                      action: session is SessionActive
                          ? (session.progress.peerName == p.name
                                ? NearbyPhoneAction.busy
                                : NearbyPhoneAction.none)
                          : p.sharesGroups
                          ? NearbyPhoneAction.sync
                          : NearbyPhoneAction.pair,
                      onAction: () => startSyncWith(context, ref, p),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: ink2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    S.encrypted,
                    style: theme.textTheme.bodySmall!.copyWith(color: ink2),
                  ),
                ),
              ],
            ),
          ),
          if (history.isNotEmpty)
            gutter(
              ListSection(
                title: S.recentSyncs,
                children: [
                  for (final r in history.take(5))
                    KitListRow(
                      title: r.peerName,
                      subtitle: S.recentLine(
                        DateLabels.ago(r.endedAt, now: now),
                        r.transport == TransportKind.lan ? S.wifi : S.bluetooth,
                      ),
                      trailing: Text(
                        S.sentGot(r.sentOps, r.receivedOps),
                        style: theme.textTheme.bodySmall!.copyWith(color: ink2),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A compact strip while a session runs or just ended; opens its screen.
class _SessionStrip extends StatelessWidget {
  const _SessionStrip({required this.session});

  final SessionStatus session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (title, subtitle) = switch (session) {
      SessionActive(:final progress) => (
        S.syncingWith(progress.peerName),
        S.keepClose,
      ),
      SessionCompleted(:final summary) => (
        S.syncedWithTitle(summary.peerName),
        S.sentAndGot(summary.sentOps, summary.receivedOps),
      ),
      SessionFailed(:final failure) => (
        S.syncStopped,
        syncFailureMessage(failure),
      ),
      SessionIdle() => ('', ''),
    };
    final Widget icon = switch (session) {
      SessionActive() => const SizedBox.square(
        dimension: 20,
        child: KitSpinner(),
      ),
      SessionFailed() => Icon(Icons.error_outline_rounded, color: scheme.error),
      _ => const Icon(Icons.check_rounded),
    };
    return Material(
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(Radii.lg),
      clipBehavior: Clip.antiAlias,
      child: KitListRow(
        title: title,
        subtitle: subtitle,
        leading: SizedBox.square(dimension: 24, child: Center(child: icon)),
        trailing: FilledButton.tonal(
          onPressed: () => context.push(Routes.syncSession),
          style: KitButtonStyles.small(context),
          child: const Text(S.viewSync),
        ),
        onTap: () => context.push(Routes.syncSession),
      ),
    );
  }
}

/// "Make this phone visible" with a live countdown.
class _HostCard extends ConsumerStatefulWidget {
  const _HostCard({required this.host, required this.onVisibleChanged});

  final HostInfo? host;
  final ValueChanged<bool> onVisibleChanged;

  @override
  ConsumerState<_HostCard> createState() => _HostCardState();
}

class _HostCardState extends ConsumerState<_HostCard>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  int _secondsLeft = -1;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(_HostCard old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    if (widget.host != null && !_ticker.isActive) {
      _ticker.start();
    } else if (widget.host == null && _ticker.isActive) {
      _ticker.stop();
    }
    _secondsLeft = _remaining();
  }

  int _remaining() {
    final host = widget.host;
    if (host == null) return -1;
    final left = host.expiresAt.difference(ref.read(clockProvider)());
    return left.isNegative ? 0 : left.inSeconds;
  }

  void _tick(Duration _) {
    final s = _remaining();
    if (s != _secondsLeft) setState(() => _secondsLeft = s);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final where = host?.wifiName != null
        ? S.onYourHotspot
        : (host?.transports.contains(TransportKind.lan) ?? false)
        ? S.onWifi
        : S.onBluetooth;
    final subtitle = host == null
        ? S.visibleOff
        : S.visibleFor(
            where,
            DateLabels.countdown(Duration(seconds: _secondsLeft)),
          );
    return GestureDetector(
      onTap: host == null ? null : () => context.push(Routes.syncHost),
      child: HostQrCard(
        visible: host != null,
        onVisibleChanged: widget.onVisibleChanged,
        subtitle: subtitle,
        qrData: host?.connectLink,
        address: host == null || host.addresses.isEmpty
            ? null
            : host.addresses.first,
        hotspotName: host?.wifiName,
      ),
    );
  }
}
