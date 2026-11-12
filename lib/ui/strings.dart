// All user-facing copy of the screens (SPEC 1.3, 10.2), in one place so it
// can be localized later. English only for the MVP.
//
// Rules (docs/design point-to-point renders, DESIGN copy rules): sentence
// case, plain verbs, name the person and the amount, direction words are
// fixed (owes you, you owe, settled up, you lent, you borrowed), one verb per
// action through a whole flow (Add expense -> Expense added), and never the
// words "offline", "device" or "user". Amounts are formatted by the caller
// with MoneyFormat and passed in as strings.
abstract final class S {
  static const appName = 'Settle Up';

  // ------------------------------------------------------------- common --
  static const cancel = 'Cancel';
  static const save = 'Save';
  static const done = 'Done';
  static const close = 'Close';
  static const back = 'Back';
  static const undo = 'Undo';
  static const delete = 'Delete';
  static const restore = 'Restore';
  static const edit = 'Edit';
  static const remove = 'Remove';
  static const rename = 'Rename';
  static const tryAgain = 'Try again';
  static const you = 'You';
  static const optional = 'Optional';
  static const moreOptions = 'More options';
  static const loading = 'Loading';
  static String people(int n) => n == 1 ? '1 person' : '$n people';
  static String joinNames(List<String> names) {
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  // --------------------------------------------------------- onboarding --
  static const onboardingTitle = 'Split costs with friends, phone to phone';
  static const onboardingBody =
      'Works without internet. When you meet, your phones sync over Wi-Fi '
      'or Bluetooth.';
  static const yourName = 'Your name';
  static const yourNameHint = 'Arjun';
  static const yourNameHelper = 'Friends see this when you sync.';
  static const homeCurrency = 'Home currency';
  static const homeCurrencyHelper = 'Groups can use other currencies.';
  static const getStarted = 'Get started';
  static const alreadyUse = 'Already use Settle Up on another phone?';
  static const syncIt = 'Sync it';
  static const comingSoon =
      'Moving to a new phone is coming soon. For now, start fresh here and '
      'sync your groups from a friend.';

  // --------------------------------------------------------------- home --
  static const searchExpenses = 'Search expenses';
  static const yourProfile = 'Settings';
  static const groups = 'Groups';
  static const peopleTitle = 'People';
  static const seeAll = 'See all';
  static const showLess = 'Show less';
  static const newGroup = 'New group';
  static const addExpense = 'Add expense';
  static const settledGroups = 'Settled groups';
  static const archivedGroups = 'Archived';
  static const waitingForFirstSync = 'Waiting for the first sync';
  static const homeEmptyHeadline = 'Start your first group';
  static const homeEmptyBody =
      "Groups keep a flat, a trip or a couple's spending in one place.";
  static const createGroup = 'Create group';
  static const joinWithQr = 'Join with a QR code';

  // -------------------------------------------------------------- group --
  static String groupSpent(String spent) => '$spent spent';
  static String groupSubtitle(int people, String spent) =>
      '${S.people(people)}, $spent spent';
  static String groupDetail(String paid, String share) =>
      'You paid $paid and your share is $share.';
  static const groupDetailNothing = 'You are not part of any expense yet.';
  static const settleUp = 'Settle up';
  static const allBalances = 'All balances';
  static const expenses = 'Expenses';
  static const invite = 'Invite to group';
  static const editGroup = 'Edit group';
  static const members = 'Members';
  static const exportCsv = 'Export as CSV';
  static const groupEmptyHeadline = 'Nothing to split yet';
  static const groupEmptyBody =
      "Add the first expense and everyone's share appears here.";
  static const everyoneSettled = 'Everyone is settled up';
  static const everyoneSettledBody =
      'No payments needed. New expenses show up here.';
  static const simplifyHelpOn = 'Fewer payments, same totals.';
  static const simplifyHelpOff = 'Showing who owes whom from each expense.';
  static const allBalancesTitle = 'All balances';
  static const getsBack = 'gets back';
  static const owes = 'owes';
  static const settled = 'settled up';
  static const deletedExpenses = 'Deleted';
  static const groupNotFound = 'This group is no longer on this phone.';
  static String notYetSharedCount(int n) =>
      n == 1 ? '1 change not yet shared' : '$n changes not yet shared';
  static const pendingGroupTitle = 'Waiting for the group';
  static const pendingGroupBody =
      'Sync with the friend who invited you to get its expenses.';
  static const openSync = 'Open sync';

  // ---------------------------------------------------- group edit/new --
  static const newGroupTitle = 'New group';
  static const editGroupTitle = 'Edit group';
  static const groupName = 'Group name';
  static const groupNameHint = 'For example, Goa trip';
  static const groupType = 'Type';
  static const typeTrip = 'Trip';
  static const typeHome = 'Home';
  static const typeCouple = 'Couple';
  static const typeOther = 'Other';
  static const currency = 'Currency';
  static const simplifyDebts = 'Simplify debts';
  static const addPeople = 'Add people';
  static const personName = 'Name';
  static const personNameHint = 'For example, Priya';
  static const addPerson = 'Add';
  static const fromYourGroups = 'From your other groups';
  static const createGroupAction = 'Create group';
  static const saveChanges = 'Save changes';
  static const archiveGroup = 'Archive group';
  static const unarchiveGroup = 'Move back to groups';
  static const deleteGroup = 'Delete group';
  static String deleteGroupTitle(String name) => 'Delete $name?';
  static String deleteGroupBody(int expenses) =>
      'This removes ${expenses == 1 ? '1 expense' : '$expenses expenses'} '
      'for everyone after the next sync.';
  static const groupCreated = 'Group created';
  static const groupSaved = 'Changes saved';
  static const groupDeleted = 'Group deleted';
  static const groupArchived = 'Group archived';
  static const nameNeeded = 'Add a name, like Goa trip';

  /// A name typed with no letter or number (only spaces, symbols or
  /// characters that show nothing).
  static const nameNeedsLetter = 'Use at least one letter or number';
  static const emoji = 'Emoji';
  static const noEmoji = 'None';
  static const youAreIncluded = "You're in this group";

  // ------------------------------------------------------------ members --
  static const membersTitle = 'Members';
  static const addMember = 'Add a person';
  static const inviteByQr = 'Invite with a QR code';
  static const inviteByQrBody =
      'Friends scan it with Settle Up to join and sync.';
  static const thisIsMe = 'This is me';
  static const mergeInto = 'Merge into…';
  static String mergeTitle(String name) => 'Merge $name into';
  static String mergeBody(String from) =>
      "$from's expenses move to the person you pick.";
  static String removeTitle(String name) => 'Remove $name?';
  static const removeBody =
      'Their past expenses stay. They are removed for everyone after the '
      'next sync.';
  static const placeholderSub = 'Not on Settle Up yet';
  static const onSettleUp = 'On Settle Up';
  static const youSub = 'You, on this phone';
  static const renameTitle = 'Rename';
  static const memberAdded = 'Person added';
  static String alreadyInGroup(String name) => '$name is already in this group';
  static String alreadyInNamedGroup(String name, String group) =>
      '$name is already in $group';
  static String alreadyAFriend(String name) =>
      'You already have a friend called $name';
  static String cannotRemoveTitle(String name) => "$name can't be removed yet";
  static String cannotRemoveBody(String name, String balance) =>
      '$name has $balance open in this group. Settle up first, then remove.';
  static const ok = 'OK';

  // ------------------------------------------------------------- invite --
  static String inviteTitle(String group) => 'Join $group';
  static const inviteBody =
      'Ask your friend to open Settle Up, tap Sync, then Scan a QR. Stay '
      'close by: the group arrives over Wi-Fi or Bluetooth.';
  static String inviteHides(String time) => 'Hides in $time';
  static const inviteHidden = 'The code is hidden to keep the group private.';
  static const showAgain = 'Show again';
  static const inviteQrLabel = 'QR code to join this group';
  static const shareLink = 'Share link';
  static const shareLinkTitle = 'Share the invite link?';
  static String shareLinkWarning(String group) =>
      'Anyone with this link can see and add to $group. Send it only to '
      'people in the group.';
  static String inviteShareText(String group, String link) =>
      'Join $group on Settle Up: $link';

  // -------------------------------------------------------------- claim --
  static const claimTitle = 'Which one are you?';
  static String claimBody(String group) =>
      'Pick your name in $group so your balances follow you.';
  static const notOnList = "I'm not on the list";
  static String claimed(String name) => "You're $name in this group";
  static const claimLater = 'Not now';
  static const claimSameNameTitle = 'Is that you?';
  static String claimSameNameBody(String name, String group) =>
      '$name is already in $group. If that is you, pick it so your '
      'balances follow you.';
  static const thatsMe = "That's me";
  static const notMe = 'Not me';
  static String yourNameIn(String group) => 'Your name in $group';
  static String nameTakenHelper(String name) =>
      '$name is already taken here. Use a name people can tell apart.';

  // -------------------------------------------------------- add expense --
  static const addExpenseTitle = 'Add expense';
  static const editExpenseTitle = 'Edit expense';
  static const discardAndClose = 'Discard and close';
  static const amount = 'Amount';
  static const description = 'Description';
  static const descriptionHint = 'What was it for?';
  static const paidBy = 'Paid by';
  static const date = 'Date';
  static const notes = 'Note';
  static const notesHint = 'Optional';
  static const category = 'Category';
  static String groupChip(String name) => 'Group: $name. Change group';
  static const pickGroup = 'Which group?';
  static const multiplePeople = 'Multiple people';
  static String peoplePaid(int n) => '$n people';
  static const whoPaid = 'Who paid?';
  static const paidHowMuch = 'How much each paid';
  static String splitHeading(String method, int included, int total) =>
      switch (method) {
        'equal' => 'Split equally between $included of $total',
        'exact' => 'Split by exact amounts',
        'percent' => 'Split by percent',
        'shares' => 'Split by shares',
        _ => 'Split equally, then adjust',
      };
  static String eachSummary(String each, int n) => '$each each, ${S.people(n)}';
  static String unevenSummary(String each, int n, int more) =>
      '$each each, ${S.people(n)}${more > 0 ? ', some pay a little more' : ''}';
  static String percentSummary(String pct) => '$pct% assigned';
  static String sharesSummary(int shares, int people) =>
      '${shares == 1 ? '1 share' : '$shares shares'}, ${S.people(people)}';
  static String exactSummary(String assigned, String total) =>
      '$assigned of $total assigned';
  static String adjustSummary(String adjusted) =>
      '$adjusted adjusted, rest split equally';
  static const saveExpense = 'Save expense';
  static const expenseAdded = 'Expense added. Shares with others on next sync.';
  static const expenseSaved = 'Changes saved. Shares with others on next sync.';
  static const descriptionNeeded = 'Add a short description, like Groceries';
  static String amountNeeded(String zero) => 'Enter an amount above $zero';
  static const splitNotDone = 'Finish the split first';
  static String payersAddUp(String paid, String total) =>
      'Paid by adds up to $paid, not $total. Tap Paid by to fix it.';
  static const splitNobody = 'Pick at least one person';
  static const splitBelowZero = 'A share would be below zero';
  static const splitUnreadable = 'Check the amounts in the split';
  static const discardTitle = 'Discard this expense?';
  static const discardBody = 'What you typed here will be lost.';
  static const keepEditing = 'Keep editing';
  static const sharesTitle = 'Shares';
  static String sharesHelper(int max) => 'A whole number from 1 to $max';
  static String setSharesOf(String name) => 'Shares for $name. Tap to type';
  static const youOweShort = 'you owe';
  static String youOweName(String name) => 'you owe $name';
  static String youGetBack(String amount) => 'you get back $amount';
  static const owesYou = 'owes you';
  static String amountOf(String name) => 'Amount for $name';
  static String percentOf(String name) => 'Percent for $name';
  static String adjustmentOf(String name) => 'Adjustment for $name';
  static const yourOwnShare = 'your own share';
  static const herOwnShare = 'own share';
  static String owesName(String name) => 'owes $name';
  static const owesPayers = 'owes the payers';
  static String sharesOf(int n) => n == 1 ? '1 share' : '$n shares';
  static const percentSuffix = '%';
  static const lessShares = 'One share less';
  static const moreShares = 'One share more';
  static const adjustHint = '+0';
  static const splitRestEqually = 'Split the rest equally';
  static const deleteExpense = 'Delete expense';
  static String deleteExpenseTitle(String name) => 'Delete $name?';
  static const deleteExpenseBody =
      'It will be removed for everyone after the next sync. You can restore '
      'it from the expense.';
  static const expenseDeleted = 'Expense deleted';
  static const expenseRestored = 'Expense restored';
  static const pickCategory = 'Category';
  static const suggested = 'Suggested';
  static const pickCurrency = 'Currency';
  static const searchCurrencies = 'Search currencies';

  // ----------------------------------------------------- expense detail --
  static const expenseTitle = 'Expense';
  static const paymentTitle = 'Payment';
  static String paidOn(String date) => 'Paid $date';
  static String addedBy(String who, String date) => 'Added by $who, $date';
  static const whoPaidTitle = 'Paid';
  static const whoOwesTitle = 'Shares';
  static const history = 'History';
  static const deletedBanner =
      'Deleted. It no longer counts towards anyone\'s balance.';
  static const conflictNote = 'Edited on two phones at once';
  static String conflictBody(String who, String time) =>
      '$who also changed the amount. We kept the version from $time.';
  static String paymentMethodLine(String method) => 'Paid by $method';
  static const notInvolved = 'You are not part of this expense.';

  // ------------------------------------------------------------- settle --
  static const settleTitle = 'Settle up';
  static String youPay(String name) => 'You pay $name';
  static String paysYou(String name) => '$name pays you';
  static String pays(String from, String to) => '$from pays $to';
  static const payPartOfIt = 'Pay part of it';
  static const changeAmount = 'Change amount';
  static const howYouPaid = 'How you paid';
  static const howTheyPaid = 'How they paid';
  static String methodNote(String method) => switch (method) {
    'upi' => 'Pay in your UPI app first. This records it; no money moves here.',
    'cash' => 'Hand over the cash first. This records it; no money moves here.',
    'bank' =>
      'Make the bank transfer first. This records it; no money moves here.',
    _ => 'Pay the way you agreed first. This records it; no money moves here.',
  };
  static const whatChanges = 'What changes';
  static String youAnd(String name) => 'You and $name';
  static String overallOf(String name) => '$name overall';
  static const yourOverall = 'Your overall';
  static const allGroups = 'All groups';
  static String recordPayment(String amount) => 'Record $amount payment';
  static const paymentRecorded = 'Payment recorded';
  static const whoIsPaying = 'Who is paying?';
  static String overpay(String extra) => "That's $extra more than the balance.";

  /// "Sam will owe you ₹10.", "You will owe Sam ₹10.", "Priya will owe
  /// Sam ₹10.": a null name is me.
  static String willOwe(String? debtor, String? creditor, String amount) =>
      '${debtor ?? 'You'} will owe ${creditor ?? 'you'} $amount.';

  /// "Priya owes": a pair cell where the one paid now owes the payer.
  static String nameOwes(String name) => '$name owes';
  static const partTitle = 'How much?';
  static const nothingToSettle = 'Nothing to settle';
  static const nothingToSettleBody = 'Everyone in this group is settled up.';
  static const pickPayment = 'Pick a payment';

  // ------------------------------------------------------------- person --
  static String personOwesYou(String name) => '$name owes you overall';
  static String youOwePerson(String name) => 'You owe $name overall';
  static String settledWith(String name) => 'You and $name are settled up';
  static const inGroups = 'By group';
  static String addExpenseWith(String name) => 'Add expense with $name';
  static const justYouTwo = 'Just you two';
  static String remindText(String name, String amount, String group) =>
      'Hi $name, a reminder from Settle Up: you owe me $amount for $group.';
  static const remind = 'Send a reminder';

  // ----------------------------------------------------------- activity --
  static const activityTitle = 'Activity';
  static const filterAll = 'All';
  static const filterExpenses = 'Expenses';
  static const filterPayments = 'Payments';
  static const filterSyncs = 'Syncs';
  static const activityEmptyHeadline = 'No activity yet';
  static const activityEmptyBody =
      'Every expense, payment and sync will be listed here.';
  static const onThisPhone = 'On this phone';
  static const notYetShared = 'not yet shared';
  static const arrivedBySync = 'Arrived by sync';
  static const bySync = 'by sync';
  static String inGroup(String g) => 'in $g';
  static String syncedWith(String name) => 'Synced with $name';
  static String syncStoppedWith(String name) => 'Sync with $name stopped';
  static String sentGot(int sent, int got) => 'Sent ${changes(sent)}, got $got';
  static String changes(int n) => n == 1 ? '1 change' : '$n changes';
  static const someone = 'Someone';

  // activity sentences: "{actor} {verb} {object}"
  static String actCreatedGroup(String a, String g) => '$a created $g';
  static String actEditedGroup(String a, String g) => '$a edited $g';
  static String actDeletedGroup(String a, String g) => '$a deleted $g';
  static String actAddedMember(String a, String m) => '$a added $m';
  static String actEditedMember(String a, String m) => '$a renamed $m';
  static String actRemovedMember(String a, String m) => '$a removed $m';
  static String actMerged(String a, String m) => '$a merged $m';
  static String actClaimed(String m) => '$m joined on their phone';
  static String actAddedExpense(String a, String e) => '$a added $e';
  static String actEditedExpense(String a, String e) => '$a edited $e';
  static String actDeletedExpense(String a, String e) => '$a deleted $e';
  static String actRestoredExpense(String a, String e) => '$a restored $e';
  static String actPayment(String a, String from, String to) =>
      a == from ? '$from paid $to' : '$a recorded $from paying $to';
  static String actEditedPayment(String a) => '$a edited a payment';
  static String actDeletedPayment(String a) => '$a deleted a payment';
  static String actRestoredPayment(String a) => '$a restored a payment';

  // ------------------------------------------------------------- search --
  static const searchHint = 'Search expenses';
  static const searchPrompt =
      'Search by description, note, category or a name.';
  static String searchNone(String q) => 'No expenses match "$q"';
  static const searchNoneBody = 'Try a shorter word or check another group.';
  static const clearSearch = 'Clear search';

  // --------------------------------------------------------------- sync --
  static const syncTitle = 'Sync';
  static const howSyncWorks = 'How sync works';
  static const howSyncWorksBody =
      'Settle Up keeps everything on this phone. When you meet friends, '
      'make one phone visible and let the other scan its QR code, or tap '
      'Sync next to a phone nearby. Phones swap only the groups they share, '
      'encrypted, over Wi-Fi, a hotspot or Bluetooth.';
  static const gotIt = 'Got it';
  static const everythingShared = 'Everything is shared';
  static String changesToShare(int n) =>
      n == 1 ? '1 change to share' : '$n changes to share';
  static String pendingBreakdown(int expenses, int payments, int other) {
    final parts = <String>[
      if (expenses > 0) expenses == 1 ? '1 expense' : '$expenses expenses',
      if (payments > 0) payments == 1 ? '1 payment' : '$payments payments',
      if (other > 0) other == 1 ? '1 other change' : '$other other changes',
    ];
    return joinNames(parts);
  }

  static String sinceLastSync(String what, String peer, String when) =>
      '$what since you last synced with $peer, $when.';
  static String sinceNever(String what) =>
      '$what made on this phone. Sync with a friend to share them.';
  static String lastSyncedWith(String peer, String when) =>
      'Last synced with $peer, $when.';
  static const neverSyncedBody =
      'Meet a friend who uses Settle Up and sync your shared groups.';
  static String yesterdayAt(String time) => 'yesterday at $time';
  static String todayAt(String time) => 'today at $time';
  static String onDateAt(String date, String time) => '$date at $time';
  static String visibleFor(String where, String time) =>
      '$where, for $time more';
  static const onYourHotspot = 'On your hotspot';
  static const onWifi = 'On this Wi-Fi';
  static const onBluetooth = 'Over Bluetooth';
  static const visibleOff = 'Off. Turn on so a friend can scan your code.';
  static const scanQr = 'Scan a QR';
  static const nearbyPhones = 'Nearby phones';
  static const looking = 'Looking';
  static const lookAgain = 'Look again';
  static const encrypted =
      'Encrypted between phones. A phone only gets the groups you both '
      'belong to.';
  static const noneNearbyHeadline = 'Looking for nearby phones';
  static const noneNearbyBody =
      'Ask your friend to open Sync and turn on Make this phone visible.';
  static const nearbyOff = 'Not looking';

  /// A phone in more groups than its advert lists, none of them ours.
  static const mayShareGroups = 'may share a group';
  static String sharesGroups(List<String> names) {
    if (names.isEmpty) return 'no shared groups';
    if (names.length == 1) return 'shares ${names.first}';
    if (names.length == 2) return 'shares ${names[0]} and ${names[1]}';
    return 'shares ${names.first} and ${names.length - 1} more';
  }

  static const wifi = 'Wi-Fi';
  static const bluetooth = 'Bluetooth';
  static const radiosAskTitle = 'Allow Bluetooth sync';
  static const radiosAskBody =
      'Settle Up needs permission to find phones near you over Bluetooth, '
      'without Wi-Fi.';
  static const allow = 'Allow';
  static const radiosDeniedTitle = 'Bluetooth sync is not allowed';
  static const radiosDeniedBody =
      'Allow the Nearby permission (Location on older phones) in the app '
      'settings for Settle Up to sync over Bluetooth.';
  static const openSettings = 'Open settings';
  static const bluetoothOffTitle = 'Bluetooth is off';
  static const bluetoothOffBody =
      'Turn it on to sync with phones that are not on your Wi-Fi.';
  static const turnOnBluetooth = 'Turn on Bluetooth';
  static const locationOffTitle = 'Location is off';
  static const locationOffBody =
      'On this version of Android, Location must be on to find phones over '
      'Bluetooth.';
  static const turnOnLocation = 'Turn on location';
  static const wifiOffTitle = 'Wi-Fi is off';
  static const wifiOffBody =
      'Turn on Wi-Fi, or join a friend\'s hotspot, to sync over Wi-Fi.';
  static const turnOnWifi = 'Turn on Wi-Fi';
  static const pairHint = 'Scan their QR code to join a group';
  static const recentSyncs = 'Recent syncs';
  static String recentLine(String when, String transport) =>
      '$when, $transport';
  static const hotspotSettings = 'Hotspot settings';
  static const showBigQr = 'Show bigger';
  static const stop = 'Stop';
  static const hostTitle = 'This phone is visible';
  static const hostBody =
      'Your friend opens Settle Up, taps Sync, then Scan a QR.';
  static String hostAddress(String a) => 'Or connect to $a';
  static const hostNoWifi =
      'No Wi-Fi? Turn on your hotspot, then your friend joins it.';
  static const turnOnVisible = 'Make this phone visible';

  // session
  static String syncingWith(String name) => 'Syncing with $name';
  static const keepClose = 'Keep both phones close until it finishes.';
  static const stepConnected = 'Connected';
  static const stepConnecting = 'Connecting';
  static const stepChecked = 'Checked it is really them';
  static const stepChecking = 'Checking it is really them';
  static const stepCompared = 'Compared changes';
  static const stepComparing = 'Comparing changes';
  static String stepSending(int done, int total) =>
      total == 0 ? 'Nothing to send' : 'Sending $done of $total';
  static String stepReceiving(int done, int total) =>
      total == 0 ? 'Receiving changes' : 'Receiving $done of $total';
  static String verification(String peer, String code) =>
      'Check that $peer shows $code';
  static String syncedWithTitle(String name) => 'Synced with $name';
  static String sentAndGot(int sent, int got) =>
      'Sent ${changes(sent)}, got ${changes(got)}.';
  static const syncStopped = 'Sync stopped';
  static String partialArrived(int got) =>
      'Nothing was lost. ${changes(got)} arrived; the rest comes next time.';
  static const nothingLost = 'Nothing was lost. Try again when close by.';
  static const sessionIdle = 'No sync running';
  static const sessionIdleBody =
      'Pick a phone nearby or scan a QR code to start.';
  static const syncRunning = 'Sync running';
  static const viewSync = 'View';

  // scan
  static const scanTitle = 'Scan a QR';
  static const scanBody =
      "Point the camera at the code on your friend's phone.";
  static const pasteLink = 'Or paste a link';
  static const pasteHint = 'settleup://…';
  static const useLink = 'Use link';
  static const cameraUnavailable =
      'The camera is not available. Paste the link instead.';
  static const joining = 'Joining';
  static String joined(String group) => 'You joined $group';
  static String alreadyIn(String group) => "You're already in $group";

  // join deep link
  static const joinTitle = 'Invitation';
  static String joinBody(String from, String group) =>
      '$from invited you to $group.';
  static const joinAction = 'Join group';
  static const badInvite =
      'This invite link is not complete. Ask for a new QR code.';

  // ----------------------------------------------------------- settings --
  static const settingsTitle = 'Settings';
  static String thisPhoneLine(String name) => 'This phone: $name';
  static const sectionMoney = 'Money';
  static const sectionAppearance = 'Appearance';
  static const sectionSync = 'Sync';
  static const sectionData = 'Data';
  static const sectionAbout = 'About';
  static const defaultSplit = 'Default split';
  static const simplifyNewGroups = 'Simplify debts in new groups';
  static const theme = 'Theme';
  static const themeSystem = 'Match system';
  static const themeLight = 'Light';
  static const themeDark = 'Dark';
  static const vibration = 'Vibration';
  static const phoneName = 'Phone name';
  static const phoneNameHelp = 'Shown to nearby phones when you sync.';
  static const exportGroupCsv = 'Export a group as CSV';
  static const exportPick = 'Which group?';
  static String csvSubject(String group) => '$group expenses';
  static const licenses = 'Licenses';
  static const version = 'Version';
  static const editName = 'Your name';
  static const noGroupsToExport = 'Create a group first.';

  // ------------------------------------------------------------- errors --
  static const errNotOnboarded = 'Finish setting up first.';
  static const errGroupNotFound = 'This group is no longer on this phone.';
  static const errMemberNotFound = 'That person is no longer in this group.';
  static const errExpenseNotFound = 'This expense is no longer on this phone.';
  static const errInvalidInput = 'Check the highlighted fields.';
  static const errInvalidSplit = 'The split does not add up to the total.';
  static const errGroupFull = 'A group can have up to 50 people.';
  static const errTooLong = 'That is too long. Make it shorter.';
  static const missingKeyTitle = "This phone can't sync this group";
  static const missingKeyBody =
      'Its key was lost on this phone. Your expenses are still here. Ask a '
      'friend in the group to show the invite QR again, then scan it.';
  static const errStorage =
      'Could not save on this phone. Make sure it has some free storage, '
      'then try again.';
  static const errPermission =
      "Settle Up needs permission to find friends' phones nearby.";
  static const errRadioOff =
      'Bluetooth or Wi-Fi is off. Turn it on to find nearby phones.';
  static const errLocationOff =
      'Location is off. Turn on location to sync over Bluetooth, or use '
      'Wi-Fi.';
  static const errUnreachable =
      "Couldn't reach that phone. Check you're on the same Wi-Fi or hotspot.";
  static const errTimeout = 'That phone stopped answering. Try again close by.';
  static const errNoShared =
      'You have no groups in common yet. Scan their QR code to join one.';
  static const errAuth =
      "The phones couldn't confirm each other. Scan a fresh QR code.";
  static const errProtocol =
      'That phone runs a different version of Settle Up. Update both apps.';
  static const errLost = 'The connection dropped. Move closer and try again.';
  static const errInvalidCode = "That code isn't a Settle Up link.";
  static const errCancelled = 'Sync cancelled.';
  static const errInternal = 'Something went wrong on this phone. Try again.';
  static const errGeneric = 'That did not work. Try again.';

  // Startup error screen (shown when the data on this phone can't be opened).
  static const startupTitle = "Settle Up couldn't start";
  static const startupStorage =
      "This phone didn't give Settle Up a place to keep its data. "
      'Restart the phone, then try again.';
  static const startupDatabase =
      "Settle Up couldn't open the expenses saved on this phone.";
  static const startupTooNew =
      'Your expenses were saved by a newer version of Settle Up. '
      'Install the latest version to open them.';
  static const startupGeneric = 'Something went wrong while opening the app.';
  static const startupKept =
      'Your data stays on this phone as it is. Nothing has been deleted.';
  static const startupRetry = 'Try again';
}
