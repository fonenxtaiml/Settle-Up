// Shared helpers for the screens: gutters, app bars, async states, error
// copy, snack bars, confirmations and small ledger lookups.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/balances.dart';
import '../../core/categories.dart';
import '../../core/ids.dart';
import '../../core/ledger_state.dart';
import '../../data/repositories.dart';
import '../../sync/sync_engine.dart';
import '../../theme/tokens.dart';
import '../strings.dart';
import '../widgets/kit_strings.dart';
import '../widgets/widgets.dart';

/// "Now" for every screen. Tests and goldens override it with a fixed time.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Container gutter (16 dp): grouped lists, cards, buttons.
Widget gutter(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Space.screen),
  child: child,
);

/// Text gutter (20 dp): headings and paragraphs line up with card text.
Widget textGutter(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Space.text),
  child: child,
);

/// The plain M3 app bar used on every screen, with the kit's spacing.
PreferredSizeWidget screenAppBar({
  required Widget title,
  Widget? leading,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
}) => AppBar(
  leading: leading,
  automaticallyImplyLeading: false,
  titleSpacing: leading == null ? Space.text : 0,
  title: title,
  bottom: bottom,
  actions: [
    for (var i = 0; i < actions.length; i++) ...[
      if (i > 0) const SizedBox(width: Space.xs),
      actions[i],
    ],
  ],
);

/// Back arrow that pops, or goes to [fallback] when nothing is below.
class BackArrow extends StatelessWidget {
  const BackArrow({super.key, this.close = false, this.onPressed});

  final bool close;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
    tooltip: close ? S.close : S.back,
    icon: Icon(close ? Icons.close_rounded : Icons.arrow_back_rounded),
  );
}

/// Loading and error states for an [AsyncValue] body.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder});

  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncData(:final value) => builder(value),
    AsyncError(:final error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Text(errorMessage(error), textAlign: TextAlign.center),
      ),
    ),
    _ => const Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  };
}

/// Maps ledger and sync errors to copy. Raw exception text is never shown.
String errorMessage(Object error) => switch (error) {
  LedgerException(:final code) => switch (code) {
    LedgerErrorCode.notOnboarded => S.errNotOnboarded,
    LedgerErrorCode.groupNotFound => S.errGroupNotFound,
    LedgerErrorCode.memberNotFound => S.errMemberNotFound,
    LedgerErrorCode.expenseNotFound => S.errExpenseNotFound,
    LedgerErrorCode.invalidInput => S.errInvalidInput,
    LedgerErrorCode.invalidSplit => S.errInvalidSplit,
  },
  SyncException(:final failure) => syncFailureMessage(failure),
  _ => S.errGeneric,
};

String syncFailureMessage(SyncFailure f) => switch (f) {
  SyncFailure.permissionDenied => S.errPermission,
  SyncFailure.radioOff => S.errRadioOff,
  SyncFailure.peerUnreachable => S.errUnreachable,
  SyncFailure.timeout => S.errTimeout,
  SyncFailure.noSharedGroups => S.errNoShared,
  SyncFailure.authFailed => S.errAuth,
  SyncFailure.protocolMismatch => S.errProtocol,
  SyncFailure.connectionLost => S.errLost,
  SyncFailure.invalidCode => S.errInvalidCode,
  SyncFailure.cancelled => S.errCancelled,
  SyncFailure.internal => S.errInternal,
};

/// A floating snack bar; replaces the one on screen.
void showSnack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
}

/// Runs [action]; on failure shows the mapped error copy. Returns success.
Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } on Object catch (e) {
    if (context.mounted) {
      Haptics.invalid(context);
      showSnack(context, errorMessage(e));
    }
    return false;
  }
}

/// A two-button confirmation. The confirm label is the action verb.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(S.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// A single-line text prompt ("Rename", "Your name", "Phone name").
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? helper,
  String confirmLabel = S.save,
}) => showDialog<String>(
  context: context,
  builder: (context) => _TextPrompt(
    title: title,
    initial: initial,
    hint: hint,
    helper: helper,
    confirmLabel: confirmLabel,
  ),
);

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.initial,
    required this.confirmLabel,
    this.hint,
    this.helper,
  });

  final String title;
  final String initial;
  final String? hint;
  final String? helper;
  final String confirmLabel;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _controller.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        hintText: widget.hint,
        helperText: widget.helper,
        helperMaxLines: 3,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(S.cancel),
      ),
      ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => FilledButton(
          onPressed: _controller.text.trim().isEmpty ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------- lookups --

String firstName(String name) => KitStrings.firstName(name);

/// My member in [g], resolved through merges.
MemberId? myMemberIn(GroupState g, PersonId me) {
  final m = g.memberForPerson(me);
  return m == null ? null : g.resolve(m.id);
}

/// First names for every member id (merged ids map to the survivor's
/// name); "You" for me.
Map<MemberId, String> memberNames(GroupState g, PersonId me) {
  final mine = myMemberIn(g, me);
  return {
    for (final m in g.members.values)
      m.id: g.resolve(m.id) == mine
          ? S.you
          : firstName(g.members[g.resolve(m.id)]?.displayName ?? m.displayName),
  };
}

/// Full names for every member id, resolved through merges.
Map<MemberId, String> memberFullNames(GroupState g) => {
  for (final m in g.members.values)
    m.id: g.members[g.resolve(m.id)]?.displayName ?? m.displayName,
};

/// The name a group is shown with. A direct group is named after the
/// other person.
String groupTitle(GroupState g, PersonId me) {
  final group = g.group;
  if (group == null) return '';
  if (!group.isDirect) return group.name;
  for (final m in g.activeMembers) {
    if (m.personId != me) return m.displayName;
  }
  return group.name;
}

/// Sum of expense totals (payments excluded) in [currency].
int spentIn(GroupState g, String currency) => g.liveExpenses
    .where((e) => !e.isPayment && e.money.currency == currency)
    .fold(0, (a, e) => a + e.money.total);

/// What I paid and my share across expenses (payments excluded).
({int paid, int share}) myPaidAndShare(
  GroupState g,
  MemberId me,
  String currency,
) {
  var paid = 0;
  var share = 0;
  for (final e in g.liveExpenses) {
    if (e.isPayment || e.money.currency != currency) continue;
    e.money.paid.forEach((m, v) {
      if (g.resolve(m) == me) paid += v;
    });
    e.money.owed.forEach((m, v) {
      if (g.resolve(m) == me) share += v;
    });
  }
  return (paid: paid, share: share);
}

/// The main currency of a balance map: [preferred] if present, else the
/// largest absolute amount.
String mainCurrencyOf(Map<String, int> net, String preferred) {
  if (net.isEmpty || net.containsKey(preferred)) return preferred;
  return (net.entries.toList()
        ..sort((a, b) => b.value.abs().compareTo(a.value.abs())))
      .first
      .key;
}

/// Short category label for chips ("Transport", "Dining out").
String categoryLabel(String id) {
  if (id == Categories.payment) return S.paymentTitle;
  final c = Categories.byId(id);
  return switch (c.id) {
    'transport' => 'Transport',
    'food' => 'Food',
    'general' => 'General',
    _ => c.label,
  };
}

/// Group nets for one currency where [me] is involved, signed from my view.
int pairNetInGroup(GroupState g, MemberId me, MemberId other) {
  var net = 0;
  for (final t in BalanceCalculator.suggestedTransfers(g)) {
    if (t.from == me && t.to == other) net -= t.amount;
    if (t.to == me && t.from == other) net += t.amount;
  }
  return net;
}

/// The group's first currency for display ("₹38,400 spent").
String groupCurrency(GroupState g) => g.group?.currency ?? 'INR';

/// True when the member is [me] after resolving merges.
bool isMeIn(GroupState g, MemberId member, PersonId me) =>
    g.resolve(member) == myMemberIn(g, me);
