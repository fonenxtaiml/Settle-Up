import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'kit_strings.dart';

/// The extended ink FAB (render 1, 2): 56 dp, 16 dp radius, plus icon and
/// "Add expense". Only the FAB and sheets cast a shadow in this design.
class AddExpenseFab extends StatelessWidget {
  const AddExpenseFab({
    super.key,
    required this.onPressed,
    this.label = KitStrings.addExpense,
    this.icon = Icons.add_rounded,
    this.heroTag,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData icon;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shadow = dark ? const Color(0xFF000000) : const Color(0xFF16191D);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.fab)),
        boxShadow: [
          BoxShadow(
            color: shadow.withValues(alpha: dark ? 0.5 : 0.18),
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: shadow.withValues(alpha: dark ? 0.4 : 0.16),
            offset: const Offset(0, 6),
            blurRadius: 16,
          ),
        ],
      ),
      child: FloatingActionButton.extended(
        heroTag: heroTag,
        onPressed: onPressed,
        icon: Icon(icon, size: 24),
        label: Text(label),
      ),
    );
  }
}

/// Bottom navigation (render 1, 5): Home, Activity, Sync on stone, with a
/// count badge on Sync for changes waiting to be shared.
class AppNavigationBar extends StatelessWidget {
  const AppNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.pendingCount = 0,
  });

  /// 0 Home, 1 Activity, 2 Sync.
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final badge = pendingCount > 0;
    final count = pendingCount > 99 ? '99+' : '$pendingCount';
    Widget syncIcon() => Badge(
      isLabelVisible: badge,
      label: Text(count),
      offset: const Offset(10, -6),
      child: const Icon(Icons.sync_alt_rounded),
    );
    // 8 dp side padding, as in render 1; the bar colour runs edge to edge.
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        child: _bar(syncIcon, badge),
      ),
    );
  }

  Widget _bar(Widget Function() syncIcon, bool badge) {
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: KitStrings.home,
        ),
        const NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long_rounded),
          label: KitStrings.activity,
        ),
        NavigationDestination(
          icon: syncIcon(),
          selectedIcon: syncIcon(),
          label: KitStrings.sync,
          tooltip: badge
              ? '${KitStrings.sync}, ${KitStrings.changesToShare(pendingCount)}'
              : KitStrings.sync,
        ),
      ],
    );
  }
}

/// App bar title with an optional subline (render 2, 4): "Goa trip" over
/// "6 people, ₹38,400 spent".
class AppBarTitle extends StatelessWidget {
  const AppBarTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge,
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Outlined chip with an expand chevron (render 3, the group picker
/// "Goa trip" in the Add expense app bar): 34 dp, 10 dp radius.
class DropdownChip extends StatelessWidget {
  const DropdownChip({
    super.key,
    required this.label,
    required this.onTap,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onTap;

  /// Defaults to [label]; for example "Group: Goa trip. Change group".
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(10));
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Material(
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: scheme.outline),
          ),
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(11, 4, 8, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall!.copyWith(
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: scheme.onSurface,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
