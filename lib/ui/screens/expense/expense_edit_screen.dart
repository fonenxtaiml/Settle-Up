// Add / edit expense (render 3): the amount first, then description with a
// suggested category, who paid and when, and the split with all five
// methods and a live "left to split" check above Save.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/categories.dart';
import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../core/money.dart';
import '../../../core/split.dart';
import '../../../data/repositories.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../format/amount_input.dart';
import '../../format/dates.dart';
import '../../format/money_format.dart';
import '../../format/unit_input_formatter.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/kit_strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../pickers.dart';
import 'category_hints.dart';
import 'payment_edit.dart';
import 'split_draft.dart';

/// Stand-in member ids while a 1:1 group with a person does not exist yet.
const String _meStandIn = 'standin-me';
const String _themStandIn = 'standin-them';

class ExpenseEditScreen extends ConsumerStatefulWidget {
  const ExpenseEditScreen({
    super.key,
    this.groupId,
    this.personId,
    this.expenseId,
  });

  final GroupId? groupId;
  final PersonId? personId;
  final ExpenseId? expenseId;

  @override
  ConsumerState<ExpenseEditScreen> createState() => _ExpenseEditScreenState();
}

/// The least room the group chip gets in the app bar before it moves to
/// the top of the form.
const double _minGroupInBar = 120;

class _ExpenseEditScreenState extends ConsumerState<ExpenseEditScreen> {
  final _description = TextEditingController();
  final _notes = TextEditingController();
  final Map<String, TextEditingController> _inputs = {};

  bool _ready = false;
  Expense? _editing;

  GroupId? _groupId;
  // A 1:1 group to create on save: (personId, name).
  (PersonId, String)? _direct;
  String _currency = 'INR';
  int? _amount;
  int _amountKey = 0;
  String _category = Categories.general;
  bool _categoryPicked = false;
  late DateTime _date;
  MemberId? _payer;
  Map<MemberId, int>? _multiPaid;
  SplitDraft _split = SplitDraft(members: const []);
  List<MemberId> _order = const [];
  Map<MemberId, String> _names = const {};
  Map<MemberId, String> _fullNames = const {};
  MemberId? _me;

  bool _triedSave = false;
  bool _saving = false;

  /// The user changed something since the screen opened; Android back and
  /// Close then ask before throwing it away.
  bool _dirty = false;
  bool _saved = false;

  void _touch() => _dirty = true;

  Future<void> _confirmDiscard() async {
    final discard = await confirmAction(
      context,
      title: S.discardTitle,
      body: S.discardBody,
      confirmLabel: S.discardAndClose,
      cancelLabel: S.keepEditing,
    );
    if (!discard || !mounted) return;
    setState(() => _dirty = false);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _notes.dispose();
    for (final c in _inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------- setup --

  void _init() {
    if (_ready) return;
    final snap = ref.read(ledgerProvider).value;
    final profile = ref.read(profileProvider).value;
    final settings = ref.read(appSettingsProvider).value ?? const AppSettings();
    if (snap == null || profile == null) return;
    _ready = true;
    _date = ref.read(clockProvider)();
    final state = snap.state;

    if (widget.expenseId != null) {
      final gid = widget.groupId;
      final e = gid == null
          ? state.expense(widget.expenseId!)
          : state.expenseIn(gid, widget.expenseId!);
      if (e == null) return;
      _editing = e;
      final g = state.groups[e.groupId]!;
      _useGroup(g, profile.personId, settings, keepSplit: true);
      final currency = Currencies.of(e.money.currency);
      _currency = e.money.currency;
      _amount = e.money.total;
      _description.text = e.description;
      _notes.text = e.notes;
      _category = e.category;
      _categoryPicked = true;
      _date = e.date.toLocal();
      final paid = e.money.paidBy.values;
      if (e.money.paidBy.method == SplitMethod.exact && paid.length == 1) {
        _payer = paid.keys.first;
      } else {
        _multiPaid = Map.of(e.money.paid);
      }
      _split.load(e.money.owedBy, currency);
      _order = _orderFor(g, profile.personId);
      _syncInputs();
      return;
    }

    if (widget.personId != null) {
      for (final g in state.visibleGroups) {
        if (g.group!.isDirect &&
            g.memberForPerson(profile.personId) != null &&
            g.memberForPerson(widget.personId!) != null) {
          _useGroup(g, profile.personId, settings);
          return;
        }
      }
      final people = Summaries2.peopleNames(state, profile.personId);
      final name = people[widget.personId!] ?? S.someone;
      _direct = (widget.personId!, name);
      _currency = profile.homeCurrency;
      _me = _meStandIn;
      _payer = _meStandIn;
      _names = {_meStandIn: S.you, _themStandIn: firstName(name)};
      _fullNames = {_meStandIn: profile.displayName, _themStandIn: name};
      _order = const [_meStandIn, _themStandIn];
      _split = SplitDraft(members: _order, method: settings.defaultSplit);
      _split.switchTo(settings.defaultSplit, 0, Currencies.of(_currency));
      return;
    }

    GroupState? g;
    if (widget.groupId != null) g = state.groups[widget.groupId!];
    if (g == null || g.group == null) {
      // The first active group: never start an expense in an archived one
      // (the group picker hides those too).
      final summaries = ref.read(groupSummariesProvider).value ?? const [];
      for (final s in summaries) {
        if (!s.group.group!.archived) {
          g = s.group;
          break;
        }
      }
      // Only 1:1 groups left: the first of those.
      g ??= state.visibleGroups
          .where((x) => x.group!.isDirect && !x.group!.archived)
          .firstOrNull;
    }
    if (g != null) _useGroup(g, profile.personId, settings);
  }

  void _useGroup(
    GroupState g,
    PersonId me,
    AppSettings settings, {
    bool keepSplit = false,
  }) {
    _groupId = g.groupId;
    _direct = null;
    _currency = g.group!.currency;
    _me = myMemberIn(g, me);
    _names = memberNames(g, me);
    _fullNames = memberFullNames(g);
    final members = [for (final m in g.activeMembers) m.id];
    _payer = _me ?? (members.isEmpty ? null : members.first);
    _multiPaid = null;
    _order = _orderFor(g, me);
    _split = SplitDraft(members: _order, method: SplitMethod.equal);
    if (!keepSplit) {
      _split.switchTo(
        settings.defaultSplit,
        _amount ?? 0,
        Currencies.of(_currency),
      );
      _syncInputs();
    }
  }

  /// You first, then whoever paid, then the others included, then the rest.
  List<MemberId> _orderFor(GroupState g, PersonId me) {
    final active = [for (final m in g.activeMembers) m.id];
    final mine = myMemberIn(g, me);
    final payers = _multiPaid?.keys.toSet() ?? {?_payer};
    int rank(MemberId m) {
      if (m == mine) return 0;
      if (payers.contains(m)) return 1;
      if (_split.included.contains(m)) return 2;
      return 3;
    }

    final out = [...active];
    // Members of an edited expense who were removed later stay listed.
    for (final m in _split.included) {
      if (!out.contains(m)) out.add(m);
    }
    // Ties keep the order people joined the group.
    DateTime joined(MemberId m) =>
        g.members[m]?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final index = {for (final (i, m) in out.indexed) m: i};
    out.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      if (c != 0) return c;
      final j = joined(a).compareTo(joined(b));
      return j != 0 ? j : index[a]!.compareTo(index[b]!);
    });
    _split.members = out;
    return out;
  }

  /// Re-sorts the split list after the payer changes: you, whoever paid,
  /// the people in the expense, then the rest.
  void _reorder() {
    final g = _groupId == null
        ? null
        : ref.read(ledgerProvider).value?.state.groups[_groupId];
    final me = ref.read(profileProvider).value?.personId;
    if (g == null || me == null) return;
    _order = _orderFor(g, me);
  }

  Currency get _cur => Currencies.of(_currency);

  TextEditingController _input(String key) =>
      _inputs.putIfAbsent(key, TextEditingController.new);

  /// Copies the draft's raw values into the text fields.
  void _syncInputs() {
    for (final m in _split.members) {
      _input('exact:$m').text = _split.exact[m] ?? '';
      _input('percent:$m').text = _split.percent[m] ?? '';
      _input('adjust:$m').text = _split.adjust[m] ?? '';
    }
  }

  // ------------------------------------------------------------ derived --

  SplitSpec get _paidSpec {
    final multi = _multiPaid;
    if (multi != null) {
      return SplitSpec(SplitMethod.exact, {
        for (final e in multi.entries)
          if (e.value > 0) e.key: e.value,
      });
    }
    return SplitSpec.single(_payer ?? '', _amount ?? 0);
  }

  bool get _paidValid {
    final multi = _multiPaid;
    if (multi == null) return _payer != null;
    return _multiPaidSum == (_amount ?? 0);
  }

  int get _multiPaidSum =>
      (_multiPaid ?? const <MemberId, int>{}).values.fold(0, (a, b) => a + b);

  String get _payerLabel {
    final multi = _multiPaid;
    if (multi != null) {
      final payers = multi.entries.where((e) => e.value > 0).toList();
      if (payers.length == 1) return _names[payers.first.key] ?? S.someone;
      return S.peoplePaid(payers.length);
    }
    return _names[_payer] ?? S.someone;
  }

  // ------------------------------------------------------------ actions --

  Future<void> _pickGroup() async {
    final profile = ref.read(profileProvider).value;
    final snap = ref.read(ledgerProvider).value;
    if (profile == null || snap == null) return;
    final groups =
        [
          for (final g in snap.state.visibleGroups)
            if (g.memberForPerson(profile.personId) != null &&
                !g.group!.archived)
              g,
        ]..sort(
          (a, b) => groupTitle(a, profile.personId).toLowerCase().compareTo(
            groupTitle(b, profile.personId).toLowerCase(),
          ),
        );
    final picked = await pickOption<GroupId>(
      context,
      title: S.pickGroup,
      selected: _groupId,
      options: [
        for (final g in groups) (g.groupId, groupTitle(g, profile.personId)),
      ],
    );
    if (picked == null || picked == _groupId || !mounted) return;
    final settings = ref.read(appSettingsProvider).value ?? const AppSettings();
    setState(() {
      _touch();
      _useGroup(snap.state.groups[picked]!, profile.personId, settings);
    });
  }

  Future<void> _pickCurrency() async {
    final home = ref.read(profileProvider).value?.homeCurrency;
    final code = await pickCurrency(
      context,
      selected: _currency,
      pinned: [?home],
    );
    if (code == null || !mounted) return;
    setState(() {
      _touch();
      _currency = code;
      _amountKey++;
      _amount = null;
    });
  }

  Future<void> _pickCategory() async {
    final id = await pickCategory(
      context,
      selected: _category,
      suggestedId: suggestCategory(_description.text),
    );
    if (id == null || !mounted) return;
    setState(() {
      _touch();
      _category = id;
      _categoryPicked = true;
    });
  }

  Future<void> _pickDate() async {
    final now = ref.read(clockProvider)();
    final d = await pickEntryDate(context, initial: _date, now: now);
    if (d == null || !mounted) return;
    setState(() {
      _touch();
      _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute);
    });
  }

  Future<void> _pickPayer() async {
    const multiple = '__multiple__';
    final picked = await pickOption<String>(
      context,
      title: S.whoPaid,
      selected: _multiPaid == null ? _payer : multiple,
      leading: (id) => id == multiple
          ? const Icon(Icons.group_outlined)
          : PersonAvatar(
              id: id,
              name: _fullNames[id] ?? '',
              size: Sizes.avatarSmall,
              isMe: id == _me,
            ),
      options: [
        for (final m in _order) (m, _names[m] ?? S.someone),
        (multiple, S.multiplePeople),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked != multiple) {
      setState(() {
        _touch();
        _payer = picked;
        _multiPaid = null;
        _reorder();
      });
      return;
    }
    final result = await showModalBottomSheet<Map<MemberId, int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => MultiPayerSheet(
        members: _order,
        names: _names,
        fullNames: _fullNames,
        me: _me,
        total: _amount ?? 0,
        currency: _currency,
        initial: _multiPaid ?? {?_payer: _amount ?? 0},
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _touch();
      _multiPaid = result;
      _reorder();
    });
  }

  void _setMethod(SplitMethod m) {
    setState(() {
      _touch();
      _split.switchTo(m, _amount ?? 0, _cur);
      _syncInputs();
    });
  }

  Future<void> _save() async {
    setState(() => _triedSave = true);
    final amount = _amount ?? 0;
    final description = _description.text.trim();
    final check = _split.check(amount, _cur);
    if (amount <= 0 ||
        description.isEmpty ||
        !check.isValid ||
        _split.badInput(_cur).isNotEmpty ||
        !_paidValid ||
        _saving) {
      Haptics.invalid(context);
      return;
    }
    setState(() => _saving = true);
    final ledger = ref.read(ledgerRepositoryProvider);
    var groupId = _groupId;
    var paid = _paidSpec;
    var owed = _split.spec(_cur);
    final ok = await runGuarded(context, () async {
      final direct = _direct;
      if (direct != null) {
        groupId = await ledger.directGroupWith(
          personId: direct.$1,
          displayName: direct.$2,
          currency: _currency,
        );
        final g = ledger.current.state.groups[groupId]!;
        final me = ref.read(profileProvider).value!.personId;
        final map = {
          _meStandIn: myMemberIn(g, me)!,
          _themStandIn: g.resolve(g.memberForPerson(direct.$1)!.id),
        };
        SplitSpec remap(SplitSpec s) => SplitSpec(s.method, {
          for (final e in s.values.entries) map[e.key]!: e.value,
        });
        paid = remap(paid);
        owed = remap(owed);
      }
      final draft = ExpenseDraft(
        groupId: groupId!,
        description: description,
        total: amount,
        currency: _currency,
        paidBy: paid,
        owedBy: owed,
        category: _category,
        date: _date.toUtc(),
        notes: _notes.text.trim(),
      );
      if (_editing != null) {
        await ledger.updateExpense(_editing!.id, draft);
      } else {
        final id = await ledger.addExpense(draft);
        if (!mounted) return;
        Haptics.medium(context);
        showSnack(
          context,
          S.expenseAdded,
          actionLabel: S.undo,
          onAction: () => ledger.deleteExpense(id, groupId: draft.groupId),
        );
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    _saved = true;
    if (_editing != null) {
      Haptics.medium(context);
      showSnack(context, S.expenseSaved);
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(groupId == null ? Routes.home : Routes.group(groupId!));
    }
  }

  // -------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerProvider);
    ref.watch(profileProvider);
    _init();
    final editing = _editing;
    if (editing != null && editing.isPayment) {
      return PaymentEditScreen(expense: editing);
    }
    final title = editing == null ? S.addExpenseTitle : S.editExpenseTitle;
    if (!_ready || (_groupId == null && _direct == null)) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(close: true),
          title: Text(title),
        ),
        body: _ready
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: EmptyState(
                    headline: S.homeEmptyHeadline,
                    body: S.homeEmptyBody,
                    actionLabel: S.createGroup,
                    onAction: () => context.pushReplacement(Routes.newGroup),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      );
    }

    final snap = ref.read(ledgerProvider).value!;
    final me = ref.read(profileProvider).value!.personId;
    final groupName = _direct != null
        ? _direct!.$2
        : groupTitle(snap.state.groups[_groupId]!, me);
    final amount = _amount ?? 0;
    final check = _split.check(amount, _cur);
    final shares = check.shares ?? const <MemberId, int>{};
    final left = _split.leftMinor(amount, _cur);
    final suggested = _categoryPicked
        ? _category
        : (suggestCategory(_description.text) ?? Categories.general);
    _category = suggested;
    final descriptionError = _triedSave && _description.text.trim().isEmpty
        ? S.descriptionNeeded
        : null;
    final amountError = _triedSave && amount <= 0
        ? S.amountNeeded(MoneyFormat.format(0, _currency))
        : null;
    final splitProblem = switch (_split.problem(amount, _cur)) {
      SplitProblem.nobody => S.splitNobody,
      SplitProblem.belowZero => S.splitBelowZero,
      SplitProblem.unreadable => S.splitUnreadable,
      null => null,
    };
    final canSave =
        amount > 0 &&
        check.isValid &&
        _split.badInput(_cur).isEmpty &&
        _paidValid &&
        !_saving;
    // Several payers whose amounts no longer match the bill (it changed
    // after they were set): say so now, not only after a Save attempt.
    final payersOff =
        !_paidValid && (_triedSave || (_multiPaid != null && amount > 0));

    // The group name shares the app bar with the title and gives way
    // first: it gets what the title leaves and ellipsizes, and when that is
    // too little for a readable chip (small phone, large text) it moves
    // out of the bar to the top of the form, so the title stays whole.
    final theme = Theme.of(context);
    final barWidth = MediaQuery.sizeOf(context).width;
    final titleWidth = measureTextWidth(
      context,
      title,
      theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
    );
    final groupRoom =
        barWidth -
        kToolbarHeight - // the close button
        titleWidth -
        Space.sm - // the actions' end padding
        Space.xs - // the gap after the group
        Space.md; // breathing room between title and group
    final groupInBar = groupRoom >= _minGroupInBar;
    final Widget groupLabel = editing == null && widget.personId == null
        ? DropdownChip(
            label: groupName,
            onTap: _pickGroup,
            semanticLabel: S.groupChip(groupName),
          )
        : Padding(
            padding: const EdgeInsets.only(right: Space.sm),
            child: Text(
              groupName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
    return PopScope(
      canPop: !_dirty || _saved || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(close: true),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (groupInBar) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: groupRoom),
                child: Center(widthFactor: 1, child: groupLabel),
              ),
              const SizedBox(width: Space.xs),
            ],
          ],
        ),
        bottomNavigationBar: _SaveBar(
          summary: _summary(check, amount),
          problem: splitProblem,
          left: left,
          currency: _currency,
          canSave: canSave,
          onSave: _save,
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: Space.lg),
          children: [
            if (!groupInBar)
              textGutter(
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: groupLabel,
                ),
              ),
            const SizedBox(height: 6),
            textGutter(
              AmountField(
                key: ValueKey('amount-$_amountKey-$_currency'),
                currency: _currency,
                initialMinor: _amount,
                autofocus: editing == null,
                currencyName: _cur.name,
                errorText: amountError,
                onCurrencyTap: _pickCurrency,
                onChanged: (v) => setState(() {
                  _amount = v;
                  _touch();
                }),
              ),
            ),
            const SizedBox(height: 14),
            gutter(
              LabeledTextField(
                label: S.description,
                hintText: S.descriptionHint,
                controller: _description,
                errorText: descriptionError,
                textInputAction: TextInputAction.done,
                maxLength: 120,
                onChanged: (_) => setState(_touch),
                trailing: CategoryChip(
                  categoryId: _category,
                  label: categoryLabel(_category),
                  onTap: _pickCategory,
                ),
              ),
            ),
            const SizedBox(height: 10),
            gutter(
              Flex(
                direction: isLargeText(context)
                    ? Axis.vertical
                    : Axis.horizontal,
                crossAxisAlignment: isLargeText(context)
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.center,
                children: [
                  _flexible(
                    context,
                    PickerTile(
                      label: S.paidBy,
                      value: _payerLabel,
                      leading: _multiPaid == null && _payer != null
                          ? PersonAvatar(
                              id: _payer!,
                              name: _fullNames[_payer] ?? '',
                              size: Sizes.avatarTiny,
                              isMe: _payer == _me,
                            )
                          : const Icon(Icons.group_outlined, size: 20),
                      onTap: _pickPayer,
                    ),
                  ),
                  const SizedBox(width: Space.sm, height: Space.sm),
                  _flexible(
                    context,
                    PickerTile(
                      label: S.date,
                      value: DateLabels.pickerDate(
                        _date,
                        now: ref.watch(clockProvider)(),
                      ),
                      leading: const Icon(
                        Icons.calendar_today_rounded,
                        size: 20,
                      ),
                      onTap: _pickDate,
                    ),
                  ),
                ],
              ),
            ),
            if (payersOff)
              textGutter(
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.splitNotDone,
                          style: Theme.of(context).textTheme.bodySmall!
                              .copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                        if (_multiPaid != null)
                          Text(
                            S.payersAddUp(
                              MoneyFormat.format(_multiPaidSum, _currency),
                              MoneyFormat.format(amount, _currency),
                            ),
                            style: Theme.of(context).textTheme.bodySmall!
                                .copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            gutter(
              SectionHeading(
                S.splitHeading(
                  _split.method.name,
                  _split.participants.length,
                  _order.length,
                ),
              ),
            ),
            gutter(
              SplitMethodSelector(value: _split.method, onChanged: _setMethod),
            ),
            const SizedBox(height: 5),
            gutter(
              ListSection(
                dividerIndent: 64,
                children: [for (final m in _order) _memberRow(m, shares)],
              ),
            ),
            const SizedBox(height: Space.md),
            gutter(
              LabeledTextField(
                label: S.notes,
                hintText: S.notesHint,
                controller: _notes,
                maxLength: 500,
                onChanged: (_) => setState(_touch),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _flexible(BuildContext context, Widget child) =>
      isLargeText(context) ? child : Expanded(child: child);

  String _summary(SplitCheck check, int amount) {
    final n = _split.participants.length;
    final shares = check.shares;
    switch (_split.method) {
      case SplitMethod.equal:
        if (shares == null || shares.isEmpty) return S.people(n);
        final values = shares.values.toList()..sort();
        final each = MoneyFormat.format(values.first, _currency);
        return values.first == values.last
            ? S.eachSummary(each, n)
            : S.unevenSummary(each, n, values.last - values.first);
      case SplitMethod.exact:
        return S.exactSummary(
          MoneyFormat.format(check.assignedUnits, _currency),
          MoneyFormat.format(amount, _currency),
        );
      case SplitMethod.percent:
        return S.percentSummary(formatPercent(check.assignedUnits));
      case SplitMethod.shares:
        return S.sharesSummary(check.targetUnits, n);
      case SplitMethod.adjustment:
        final adjusted = _split
            .spec(_cur)
            .values
            .values
            .fold(0, (a, b) => a + b.abs());
        return S.adjustSummary(MoneyFormat.format(adjusted, _currency));
    }
  }

  /// The subline and direction for one member, from your point of view.
  (String?, MoneyDirection?) _subline(MemberId m, int? share) {
    final included = _split.included.contains(m);
    if (!included) return (null, null);
    final payers = _paidSpec.values.keys.toSet();
    final singlePayer = payers.length == 1 ? payers.first : null;
    final payerName = singlePayer == null ? null : _names[singlePayer];
    if (m == _me) {
      if (payers.contains(m)) {
        final paid = _multiPaid?[m] ?? (_amount ?? 0);
        final back = paid - (share ?? 0);
        if (back > 0) {
          return (
            S.youGetBack(MoneyFormat.format(back, _currency)),
            MoneyDirection.owed,
          );
        }
        return (S.yourOwnShare, null);
      }
      return (
        payerName == null ? S.owesPayers : S.youOweName(payerName),
        MoneyDirection.owe,
      );
    }
    if (payers.contains(m)) return (S.herOwnShare, null);
    if (singlePayer == _me) return (S.owesYou, null);
    return (payerName == null ? S.owesPayers : S.owesName(payerName), null);
  }

  Widget _memberRow(MemberId m, Map<MemberId, int> shares) {
    final included = _split.included.contains(m);
    final share = shares[m];
    final (sub, dir) = _subline(m, share);
    final isMe = m == _me;
    final payers = _paidSpec.values.keys.toSet();
    void toggle(bool v) => setState(() {
      _touch();
      if (v) {
        _split.included.add(m);
      } else {
        _split.included.remove(m);
      }
    });
    final name = _names[m] ?? S.someone;
    if (_split.method == SplitMethod.equal) {
      return MemberSplitRow(
        id: m,
        name: name,
        avatarName: _fullNames[m],
        isMe: isMe,
        included: included,
        onChanged: toggle,
        currency: _currency,
        subtitle: sub,
        subtitleDirection: dir,
        shareMinor: share,
        shareDirection: isMe && !payers.contains(m)
            ? MoneyDirection.owe
            : MoneyDirection.neutral,
      );
    }
    final Widget input = switch (_split.method) {
      SplitMethod.shares => _SharesStepper(
        value: _split.shares[m] ?? 1,
        enabled: included,
        label: S.setSharesOf(name),
        onChanged: (v) => setState(() {
          _split.shares[m] = v;
          _touch();
        }),
      ),
      SplitMethod.exact => _UnitField(
        controller: _input('exact:$m'),
        enabled: included,
        read: (t) => parseAmountInput(t, _cur),
        write: (v) => minorToInput(v, _cur),
        prefix: _cur.symbol,
        label: S.amountOf(name),
        onChanged: (v) => setState(() {
          _split.exact[m] = v;
          _touch();
        }),
      ),
      SplitMethod.percent => _UnitField(
        controller: _input('percent:$m'),
        enabled: included,
        read: parsePercent,
        write: formatPercent,
        suffix: S.percentSuffix,
        label: S.percentOf(name),
        onChanged: (v) => setState(() {
          _split.percent[m] = v;
          _touch();
        }),
      ),
      _ => _UnitField(
        controller: _input('adjust:$m'),
        enabled: included,
        read: (t) => parseSignedMinor(t, _cur),
        write: (v) => minorToInput(v, _cur),
        prefix: _cur.symbol,
        hint: S.adjustHint,
        signed: true,
        label: S.adjustmentOf(name),
        onChanged: (v) => setState(() {
          _split.adjust[m] = v;
          _touch();
        }),
      ),
    };
    final shareText = included && share != null
        ? MoneyFormat.format(share, _currency)
        : null;
    return _InputSplitRow(
      id: m,
      name: name,
      avatarName: _fullNames[m] ?? name,
      isMe: isMe,
      included: included,
      onChanged: toggle,
      subtitle: [
        if (_split.method == SplitMethod.shares && included)
          S.sharesOf(_split.shares[m] ?? 1),
        ?shareText,
        if (shareText == null) ?sub,
      ].join(', '),
      input: input,
    );
  }
}

/// Summary line and the Save button, pinned above the keyboard.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.summary,
    this.problem,
    required this.left,
    required this.currency,
    required this.canSave,
    required this.onSave,
  });

  final String summary;
  final String? problem;
  final int left;
  final String currency;
  final bool canSave;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SplitSummaryBar(
                summary: summary,
                leftMinor: left,
                currency: currency,
                problem: problem,
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: canSave ? onSave : null,
                style: KitButtonStyles.block,
                child: const Text(S.saveExpense),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Split row with an input on the right (exact, percent, shares, adjust).
class _InputSplitRow extends StatelessWidget {
  const _InputSplitRow({
    required this.id,
    required this.name,
    required this.avatarName,
    required this.isMe,
    required this.included,
    required this.onChanged,
    required this.subtitle,
    required this.input,
  });

  final String id;
  final String name;
  final String avatarName;
  final bool isMe;
  final bool included;
  final ValueChanged<bool> onChanged;
  final String subtitle;
  final Widget input;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sub = included ? subtitle : KitStrings.notInThisExpense;
    final titleStyle = included
        ? theme.textTheme.titleSmall!
        : theme.textTheme.titleSmall!.copyWith(color: scheme.onSurfaceVariant);
    final subStyle = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: titleStyle),
        // Its amount is set smaller rather than broken over two lines when
        // even the stacked column is too narrow (VISUAL-R4-03).
        if (sub.isNotEmpty) FitWordsText(sub, style: subStyle),
      ],
    );
    final inputWidth = switch (input) {
      final _UnitField f => f.widthIn(context),
      _SharesStepper() => _SharesStepper.width,
      _ => 112.0,
    };
    // The input goes under the name at large text, and earlier whenever
    // the name's longest word or an amount in the subline would not fit
    // beside it (VISUAL-R4-03): an amount is never broken over two lines.
    final textNeeds = [
      _longestWord(context, name, titleStyle),
      _longestWord(context, sub, subStyle),
    ].reduce((a, b) => a > b ? a : b);
    return LayoutBuilder(
      builder: (context, c) {
        const fixed =
            48 + // checkbox
            Sizes.avatarSmall +
            Space.md +
            Space.sm +
            16; // end padding
        final large =
            isLargeText(context) || c.maxWidth - fixed - inputWidth < textNeeds;
        return _row(context, large: large, text: text);
      },
    );
  }

  static double _longestWord(BuildContext context, String s, TextStyle st) {
    var widest = 0.0;
    for (final word in s.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: word, style: st),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (tp.width > widest) widest = tp.width;
      tp.dispose();
    }
    return widest;
  }

  Widget _row(
    BuildContext context, {
    required bool large,
    required Widget text,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(0, 4, 16, 4),
        child: Row(
          children: [
            Checkbox(
              value: included,
              semanticLabel: name,
              onChanged: (v) {
                Haptics.selection(context);
                onChanged(v ?? false);
              },
            ),
            ExcludeSemantics(
              child: PersonAvatar(
                id: id,
                name: avatarName,
                size: Sizes.avatarSmall,
                isMe: isMe,
              ),
            ),
            const SizedBox(width: Space.md),
            // The input keeps its place in the tree beside or under the
            // text, so typing never closes the keyboard (VISUAL-R5-01).
            Expanded(
              child: BesideOrUnder(
                text: text,
                trailing: input,
                stacked: large,
                gap: Space.sm,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact numeric field for one member's share.
class _UnitField extends StatelessWidget {
  const _UnitField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.label,
    required this.read,
    required this.write,
    this.prefix,
    this.suffix,
    this.hint,
    this.signed = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  /// The reader for this field's text, and how it writes a value back
  /// (see [UnitInputFormatter]).
  final int? Function(String text) read;
  final String Function(int value) write;
  final String label;
  final String? prefix;
  final String? suffix;
  final String? hint;
  final bool signed;

  /// The width that shows the whole value with its symbol (at least the
  /// design's 112 dp), so no digit scrolls out of sight (VISUAL-R4-03).
  double widthIn(BuildContext context) {
    final style = AppType.amount(context);
    final value = controller.text.isEmpty ? (hint ?? '0') : controller.text;
    final tp = TextPainter(
      text: TextSpan(
        text: '${prefix ?? ''}$value${suffix ?? ''}',
        style: style,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // Content padding (10 + 10), the caret and its gap, and a little
    // room for the next key.
    final w = tp.width + 20 + 12;
    tp.dispose();
    return w < 112 ? 112 : w;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = widthIn(context);
      if (!c.maxWidth.isFinite || c.maxWidth >= w) {
        return SizedBox(width: w, child: _field(context, 1));
      }
      // Narrower than the value (stacked under a long name at large
      // text): the value is scaled down to fit, never scrolled.
      final base = AppType.amount(context);
      final fitted = AmountField.fitted(
        base,
        '${prefix ?? ''}${controller.text}${suffix ?? ''}',
        c.maxWidth - 20 - 12,
        MediaQuery.textScalerOf(context),
        Directionality.of(context),
      );
      return SizedBox(
        width: c.maxWidth,
        child: _field(context, fitted.fontSize! / base.fontSize!),
      );
    },
  );

  Widget _field(BuildContext context, double shrink) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppType.amount(context);
    final side = theme.textTheme.bodyLarge!;
    final sideStyle = shrink >= 1
        ? null
        : side.copyWith(
            fontSize: side.fontSize! * shrink,
            color: scheme.onSurfaceVariant,
          );
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      textAlign: TextAlign.end,
      keyboardType: TextInputType.numberWithOptions(
        decimal: true,
        signed: signed,
      ),
      // See AmountField: a pasted line break must reach the reader, and
      // UnitInputFormatter keeps the text on one line.
      minLines: 1,
      maxLines: 2,
      inputFormatters: [
        UnitInputFormatter(read: read, write: write, signed: signed),
      ],
      style: shrink >= 1
          ? style
          : style.copyWith(fontSize: style.fontSize! * shrink),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint ?? '0',
        labelText: null,
        semanticCounterText: label,
        prefixText: prefix,
        suffixText: suffix,
        prefixStyle: sideStyle,
        suffixStyle: sideStyle,
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// − n + stepper for shares. The number itself can be tapped to type a
/// weight, up to [SplitCalculator]'s 1000 (SPEC 6.1).
class _SharesStepper extends StatelessWidget {
  const _SharesStepper({
    required this.value,
    required this.enabled,
    required this.label,
    required this.onChanged,
  });

  static const max = 1000;

  /// Two 48 dp buttons around the 36 dp number.
  static const double width = 48 + 36 + 48;

  final int value;
  final bool enabled;
  final String label;
  final ValueChanged<int> onChanged;

  Future<void> _type(BuildContext context) async {
    final t = await showDialog<int>(
      context: context,
      builder: (context) => _WeightPrompt(initial: value),
    );
    if (t != null) onChanged(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: S.lessShares,
          onPressed: enabled && value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        Semantics(
          button: enabled,
          label: label,
          value: '$value',
          excludeSemantics: true,
          child: InkWell(
            onTap: enabled ? () => _type(context) : null,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: SizedBox(
              width: 36,
              height: 48,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: S.moreShares,
          onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}

class _WeightPrompt extends StatefulWidget {
  const _WeightPrompt({required this.initial});

  final int initial;

  @override
  State<_WeightPrompt> createState() => _WeightPromptState();
}

class _WeightPromptState extends State<_WeightPrompt> {
  late final _c = TextEditingController(text: '${widget.initial}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.initial}'.length,
    );

  int? get _value {
    final v = int.tryParse(_c.text.trim());
    return v == null || v < 1 || v > _SharesStepper.max ? null : v;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _value;
    if (v != null) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(S.sharesTitle),
    content: TextField(
      controller: _c,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      decoration: InputDecoration(
        helperText: S.sharesHelper(_SharesStepper.max),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(S.cancel),
      ),
      FilledButton(
        onPressed: _value == null ? null : _submit,
        child: const Text(S.done),
      ),
    ],
  );
}

/// "Paid by: multiple people": an amount per payer that must add up.
class MultiPayerSheet extends StatefulWidget {
  const MultiPayerSheet({
    super.key,
    required this.members,
    required this.names,
    required this.fullNames,
    required this.me,
    required this.total,
    required this.currency,
    required this.initial,
  });

  final List<MemberId> members;
  final Map<MemberId, String> names;
  final Map<MemberId, String> fullNames;
  final MemberId? me;
  final int total;
  final String currency;
  final Map<MemberId, int> initial;

  @override
  State<MultiPayerSheet> createState() => _MultiPayerSheetState();
}

class _MultiPayerSheetState extends State<MultiPayerSheet> {
  late final Currency _cur = Currencies.of(widget.currency);
  late final Map<MemberId, TextEditingController> _c = {
    for (final m in widget.members)
      m: TextEditingController(
        text: (widget.initial[m] ?? 0) > 0
            ? minorToInput(widget.initial[m]!, _cur)
            : '',
      ),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<MemberId, int> get _values => {
    for (final e in _c.entries)
      if ((parseAmountInput(e.value.text, _cur) ?? 0) > 0)
        e.key: parseAmountInput(e.value.text, _cur)!,
  };

  /// A payer field holds text that cannot be read as an amount.
  bool get _unreadable => _c.values.any(
    (c) => c.text.trim().isNotEmpty && parseAmountInput(c.text, _cur) == null,
  );

  void _splitEvenly() {
    final payers = _values.keys.toList();
    final who = payers.isEmpty ? widget.members : payers;
    final even = SplitCalculator.allocate(widget.total, {
      for (final m in who) m: 1,
    });
    setState(() {
      for (final m in widget.members) {
        _c[m]!.text = (even[m] ?? 0) > 0 ? minorToInput(even[m]!, _cur) : '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sum = _values.values.fold(0, (a, b) => a + b);
    final left = widget.total - sum;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            textGutter(Text(S.paidHowMuch, style: theme.textTheme.titleLarge)),
            const SizedBox(height: Space.sm),
            gutter(
              ListSection(
                dividerIndent: 64,
                children: [
                  for (final m in widget.members)
                    _InputSplitRow(
                      id: m,
                      name: widget.names[m] ?? S.someone,
                      avatarName: widget.fullNames[m] ?? '',
                      isMe: m == widget.me,
                      included: true,
                      onChanged: (_) {},
                      subtitle: '',
                      input: _UnitField(
                        controller: _c[m]!,
                        enabled: true,
                        read: (t) => parseAmountInput(t, _cur),
                        write: (v) => minorToInput(v, _cur),
                        prefix: _cur.symbol,
                        label: '${S.paidBy}, ${widget.names[m]}',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, Space.md, 16, 0),
              child: SplitSummaryBar(
                summary: S.exactSummary(
                  MoneyFormat.format(sum, widget.currency),
                  MoneyFormat.format(widget.total, widget.currency),
                ),
                leftMinor: left,
                currency: widget.currency,
                problem: _unreadable ? S.splitUnreadable : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, Space.sm, 16, Space.lg),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: widget.total > 0 ? _splitEvenly : null,
                      child: const Text(S.splitRestEqually),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: FilledButton(
                      onPressed: left == 0 && sum > 0 && !_unreadable
                          ? () => Navigator.of(context).pop(_values)
                          : null,
                      child: const Text(S.done),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Display names of everyone I share a group with (for 1:1 expenses).
abstract final class Summaries2 {
  static Map<PersonId, String> peopleNames(LedgerState state, PersonId me) => {
    for (final g in state.visibleGroups)
      for (final m in g.activeMembers)
        if (m.personId != me) m.personId: m.displayName,
  };
}
