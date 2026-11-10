// "This phone lost the key for this group": shown on a group whose key the
// keystore no longer holds (LedgerSnapshot.groupsWithoutKey). The group
// still works here; scanning its invite QR again restores sync.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/tokens.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';

class MissingKeyNotice extends StatelessWidget {
  const MissingKeyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Semantics(
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.key_off_rounded, color: scheme.error),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.missingKeyTitle,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          S.missingKeyBody,
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  onPressed: () => context.push(Routes.syncScan),
                  style: KitButtonStyles.small(context),
                  child: const Text(S.scanQr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
