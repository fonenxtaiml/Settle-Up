import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'button_semantics.dart';
import 'kit_layout.dart';
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
///
/// Both lines take one line. Whatever the app bar cuts (a 60-character
/// group name, a 40-character name, a group name in the subline, any of
/// them at a large text scale) reads in full on the same screen: the
/// screen wraps its [Scaffold] in a [TitleCutScope] and puts a
/// [CutTitleHeading] at the top of its body. In debug builds an
/// [AppBarTitle] that cuts a line with no [CutTitleHeading] on its screen
/// reports an error, so a screen cannot miss it (VISUAL-R34-02).
class AppBarTitle extends StatelessWidget {
  const AppBarTitle(this.title, {super.key, this.subtitle, this.shortSubtitle});

  final String title;
  final String? subtitle;

  /// Shown instead of [subtitle] when that does not fit on one line (at
  /// large text): the part worth keeping, e.g. "₹1,20,000.50 spent".
  final String? shortSubtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final style = theme.textTheme.titleLarge;
              TitleCutScope._report(
                context,
                _Line.title,
                title,
                cut:
                    constraints.hasBoundedWidth &&
                    !textFitsWords(context, title, style, constraints.maxWidth),
              );
              return Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              );
            },
          ),
          if (subtitle != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final style = theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                );
                final fits =
                    !constraints.hasBoundedWidth ||
                    textFitsWords(
                      context,
                      subtitle!,
                      style,
                      constraints.maxWidth,
                    );
                final short = shortSubtitle;
                // The short form replaces a subline that does not fit: it
                // is the part worth keeping, and never cut.
                TitleCutScope._report(
                  context,
                  _Line.subtitle,
                  subtitle!,
                  cut: !fits && short == null,
                );
                if (short != null && !fits) {
                  // The short form is the part worth keeping: when even it
                  // does not fit one line ("KD999,999.999 spent" at 320 dp,
                  // 1.3x) it scales down rather than lose its end.
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(short, maxLines: 1, style: style),
                    ),
                  );
                }
                return Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                );
              },
            ),
        ],
      ),
    );
  }
}

/// The two lines of an [AppBarTitle].
enum _Line { title, subtitle }

/// What the app bar cuts: its title and its subline, each null while it
/// fits.
typedef _Cut = ({String? title, String? subtitle});

/// Lets a screen show its [AppBarTitle] in full when the one-line app bar
/// cuts it: wrap the screen's [Scaffold] in a [TitleCutScope] and put a
/// [CutTitleHeading] at the top of its body. The heading appears only
/// while the app bar cuts a line (a 60-character group name, a 40-
/// character name, a group name in the subline, a large text scale), so a
/// title that fits is not shown twice. Rows cap a name to one line because
/// it reads in full one tap away; this is that place (VISUAL-R34-02).
class TitleCutScope extends StatefulWidget {
  const TitleCutScope({super.key, required this.child});

  final Widget child;

  /// Records whether the app bar under [context] cut [line], [text].
  static void _report(
    BuildContext context,
    _Line line,
    String text, {
    required bool cut,
  }) {
    final state = context
        .getInheritedWidgetOfExactType<_TitleCutInherited>()
        ?.state;
    if (state == null) {
      assert(!cut || _missingHeading(text, 'no TitleCutScope'));
      return;
    }
    assert(!cut || state._verifyHeading(text));
    final value = cut ? text : null;
    final now = state._cut.value;
    final next = switch (line) {
      _Line.title => (title: value, subtitle: now.subtitle),
      _Line.subtitle => (title: now.title, subtitle: value),
    };
    if (next == now) return;
    // Reported from layout: the heading updates after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!state.mounted) return;
      final cur = state._cut.value;
      state._cut.value = switch (line) {
        _Line.title => (title: value, subtitle: cur.subtitle),
        _Line.subtitle => (title: cur.title, subtitle: value),
      };
    });
  }

  /// Reports, in debug builds, an app bar line that is cut with nowhere on
  /// its screen to read it in full.
  static bool _missingHeading(String text, String? why) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: FlutterError(
          'The app bar cuts "$text" and its screen has no CutTitleHeading'
          '${why == null ? '' : ' ($why)'}.\n'
          'Wrap the screen in a TitleCutScope and put a CutTitleHeading at '
          'the top of its body, so the line reads in full (VISUAL-R34-02).',
        ),
        library: 'settle_up ui',
      ),
    );
    return true;
  }

  @override
  State<TitleCutScope> createState() => _TitleCutScopeState();
}

class _TitleCutScopeState extends State<TitleCutScope> {
  /// The lines the app bar cuts.
  final _cut = ValueNotifier<_Cut>((title: null, subtitle: null));

  /// The [CutTitleHeading]s built under this scope. A heading in a lazy
  /// list that scrolled away still counts.
  int _headings = 0;

  /// Lines already reported as cut with no heading (debug builds).
  final _reported = <String>{};
  bool _verifying = false;

  /// Checks after this frame, once the body is built, that the screen has
  /// a [CutTitleHeading] for the cut [text]. Debug builds only.
  bool _verifyHeading(String text) {
    if (_verifying || _reported.contains(text)) return true;
    _verifying = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verifying = false;
      if (mounted && _headings == 0 && _reported.add(text)) {
        TitleCutScope._missingHeading(text, null);
      }
    });
    return true;
  }

  @override
  void dispose() {
    _cut.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _TitleCutInherited(state: this, child: widget.child);
}

class _TitleCutInherited extends InheritedWidget {
  const _TitleCutInherited({required this.state, required super.child});

  final _TitleCutScopeState state;

  @override
  bool updateShouldNotify(_TitleCutInherited old) => old.state != state;
}

/// What the app bar cuts, in full, as a heading at the top of the body
/// ([TitleCutScope]): the title in the title style, and a cut subline
/// (the group of an entry, the group being settled) under it. Each wraps
/// and is never cut; a word wider than the line sets it smaller rather
/// than break the word.
class CutTitleHeading extends StatefulWidget {
  const CutTitleHeading({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(
      Space.text,
      0,
      Space.text,
      Space.md,
    ),
  });

  final EdgeInsetsGeometry padding;

  @override
  State<CutTitleHeading> createState() => _CutTitleHeadingState();
}

class _CutTitleHeadingState extends State<CutTitleHeading> {
  _TitleCutScopeState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .getInheritedWidgetOfExactType<_TitleCutInherited>()
        ?.state;
    if (scope == _scope) return;
    // Counted for good: a heading that scrolls out of a lazy list is
    // disposed, but the screen still has it.
    _scope = scope?.._headings += 1;
  }

  @override
  Widget build(BuildContext context) {
    final state = _scope;
    if (state == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ValueListenableBuilder<_Cut>(
      valueListenable: state._cut,
      builder: (context, cut, _) {
        final (:title, :subtitle) = cut;
        if (title == null && subtitle == null) return const SizedBox.shrink();
        return Padding(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Semantics(
                  header: true,
                  child: FitWordsText(title, style: theme.textTheme.titleLarge),
                ),
              if (subtitle != null)
                FitWordsText(
                  subtitle,
                  style: theme.textTheme.bodyLarge!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        );
      },
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
    this.wrap = false,
  });

  final String label;
  final VoidCallback? onTap;

  /// Defaults to [label]; for example "Group: Goa trip. Change group".
  final String? semanticLabel;

  /// Whether the label wraps in full instead of taking one line: outside
  /// an app bar, where the chip has a line of its own (VISUAL-R34-02).
  final bool wrap;

  /// The chip's width around its label: the side padding, the gap and
  /// the chevron.
  static const double chrome = 11 + 8 + 6 + 18;

  /// The label's text style.
  static TextStyle labelStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleSmall!.copyWith(fontSize: 14);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(10));
    return ButtonSemantics(
      label: semanticLabel ?? label,
      onTap: onTap,
      // 34 dp visual chip inside a 48 dp tap target.
      child: TapTargetPadding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        onTap: onTap,
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
                      child: wrap
                          ? FitWordsText(label, style: labelStyle(context))
                          : Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: labelStyle(context),
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
