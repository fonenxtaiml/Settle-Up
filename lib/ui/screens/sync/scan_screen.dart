// Scan a QR: a group invite (join, then "Which one are you?") or a sync
// code (start a session). A pasted link works the same way.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../sync/pairing/links.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

/// Joins an invite or starts a sync from [link]; navigates on success.
/// Returns false when the link is not a Settle Up link.
Future<bool> handleSettleUpLink(
  BuildContext context,
  WidgetRef ref,
  String link,
) async {
  final engine = ref.read(syncEngineProvider);
  if (InviteLink.tryParse(link) != null) {
    try {
      final result = await engine.acceptInvite(link);
      if (!context.mounted) return true;
      if (result.alreadyMember) {
        showSnack(context, S.alreadyIn(result.groupName));
        context.pushReplacement(Routes.group(result.groupId));
      } else {
        Haptics.medium(context);
        showSnack(context, S.joined(result.groupName));
        context.pushReplacement(Routes.claim(result.groupId));
      }
    } on Object catch (e) {
      if (context.mounted) showSnack(context, errorMessage(e));
    }
    return true;
  }
  if (ConnectLink.tryParse(link) != null) {
    unawaited(
      engine.syncWithLink(link).then<void>((_) {}, onError: (Object _) {}),
    );
    if (context.mounted) context.pushReplacement(Routes.syncSession);
    return true;
  }
  return false;
}

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, this.initialLink, this.showCamera = true});

  /// A link that arrived by deep link (settleup://sync?...).
  final String? initialLink;

  /// Off in widget tests (no camera plugin).
  final bool showCamera;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _link = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLink;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _use(initial));
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _use(String link) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await handleSettleUpLink(context, ref, link.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      Haptics.invalid(context);
      showSnack(context, S.errInvalidCode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: const Text(S.scanTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          textGutter(
            Text(
              S.scanBody,
              style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
            ),
          ),
          const SizedBox(height: Space.lg),
          gutter(
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg),
              child: AspectRatio(
                aspectRatio: 1,
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainer,
                  child: widget.showCamera
                      ? MobileScanner(
                          onDetect: (capture) {
                            for (final b in capture.barcodes) {
                              final v = b.rawValue;
                              if (v != null && v.startsWith('settleup://')) {
                                unawaited(_use(v));
                                return;
                              }
                            }
                          },
                          errorBuilder: (context, error) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(Space.xl),
                              child: Text(
                                S.cameraUnavailable,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.qr_code_scanner_rounded,
                            size: 64,
                            color: ink2,
                          ),
                        ),
                ),
              ),
            ),
          ),
          gutter(const SectionHeading(S.pasteLink)),
          gutter(
            LabeledTextField(
              label: S.pasteLink,
              hintText: S.pasteHint,
              controller: _link,
              textInputAction: TextInputAction.go,
              onSubmitted: _use,
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            FilledButton(
              onPressed: _link.text.trim().isEmpty || _busy
                  ? null
                  : () => _use(_link.text),
              style: KitButtonStyles.block,
              child: Text(_busy ? S.joining : S.useLink),
            ),
          ),
        ],
      ),
    );
  }
}
