// Host mode, full screen: a big QR to scan, the address to type, the
// hotspot name and the time left. Starts hosting if it is not on yet.
import 'dart:async';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/kit_strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import 'radios.dart';

class HostScreen extends ConsumerStatefulWidget {
  const HostScreen({super.key});

  @override
  ConsumerState<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends ConsumerState<HostScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  int _left = -1;

  @override
  void initState() {
    super.initState();
    final engine = ref.read(syncEngineProvider);
    if (engine.status.host == null) {
      // Bluetooth advertising needs its permissions first (SPEC 8.10).
      unawaited(
        prepareRadios(engine)
            .then((_) => engine.startHosting())
            .then<void>(
              (_) {},
              onError: (Object e) {
                if (mounted) showSnack(context, errorMessage(e));
              },
            ),
      );
    }
    _ticker.start();
  }

  void _tick() {
    final host = ref.read(syncStatusProvider).value?.host;
    final left = host == null
        ? -1
        : host.expiresAt.difference(ref.read(clockProvider)()).inSeconds;
    if (left != _left) {
      setState(() => _left = left < 0 && host != null ? 0 : left);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final host = ref.watch(syncStatusProvider).value?.host;
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: const Text(S.hostTitle),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: host == null
              ? FilledButton(
                  onPressed: () => runGuarded(
                    context,
                    () => ref.read(syncEngineProvider).startHosting(),
                  ),
                  style: KitButtonStyles.block,
                  child: const Text(S.turnOnVisible),
                )
              : FilledButton.tonal(
                  onPressed: () async {
                    await runGuarded(
                      context,
                      () => ref.read(syncEngineProvider).stopHosting(),
                    );
                    // Only this screen closes, never what is over it or
                    // under it (MONEY-R28-01 class).
                    if (context.mounted) {
                      closeScreen(context, fallback: Routes.sync);
                    }
                  },
                  style: KitButtonStyles.block,
                  child: const Text(S.stop),
                ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Space.text),
        children: [
          Text(
            S.hostBody,
            style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
          ),
          const SizedBox(height: Space.xl),
          if (host != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  // QR codes stay dark on white in both themes.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Semantics(
                  image: true,
                  label: KitStrings.qrLabel,
                  child: QrImageView(
                    data: host.connectLink,
                    size: 232,
                    padding: EdgeInsets.zero,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF16191D),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF16191D),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.xl),
            for (final a in host.addresses)
              Text(
                S.hostAddress(a),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            if (host.wifiName != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  '${KitStrings.hotspot}: ${host.wifiName}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
                ),
              ),
            const SizedBox(height: Space.md),
            Text(
              S.visibleFor(
                S.onYourHotspot,
                DateLabels.countdown(Duration(seconds: _left < 0 ? 0 : _left)),
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
            ),
          ],
          const SizedBox(height: Space.xl),
          Text(
            S.hostNoWifi,
            style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextLink(
              S.hotspotSettings,
              onPressed: () =>
                  AppSettings.openAppSettings(type: AppSettingsType.hotspot),
            ),
          ),
        ],
      ),
    );
  }
}
