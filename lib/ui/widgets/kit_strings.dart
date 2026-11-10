// Copy used inside the design-system widgets.
//
// Screens keep their copy in lib/ui/strings.dart (owned by ui-screens).
// The widget kit cannot depend on that file, so the few phrases the
// widgets render themselves live here, written to the same rules: sentence
// case, amounts from the user's view with a direction word, "this phone"
// rather than "device", never "offline".
import '../format/money_format.dart';

abstract final class KitStrings {
  // Direction words (DESIGN.md "Do's and Don'ts"). Fixed everywhere.
  static const owesYou = 'owes you';
  static const youOwe = 'you owe';
  static const youreOwed = "you're owed";
  static const settledUp = 'settled up';
  static const settled = 'settled';
  static const youLent = 'you lent';
  static const youBorrowed = 'you borrowed';
  static const notInvolved = 'not involved';
  static const received = 'received';
  static const paid = 'paid';
  static const getsBack = 'gets back';
  static const owes = 'owes';

  // Balance hero (Home).
  static const heroOwed = "You're owed overall";
  static const heroOwe = 'You owe overall';
  static const heroSettled = "You're all settled up";
  static const comingToYou = 'Coming to you';
  static const youOweColumn = 'You owe';
  static String plusOtherOwed(String amount) => 'Plus $amount owed to you';
  static String plusOtherOwe(String amount) => 'Plus $amount you owe';

  // Group position hero.
  static const groupOwe = 'You owe in this group';
  static const groupOwed = "You're owed in this group";
  static const groupSettled = "You're settled up in this group";

  static String moreCurrencies(int n) => '+$n more';

  // Expense rows.
  static String paidAmount(String payer, String amount) =>
      '$payer paid $amount';
  static String peoplePaid(int n, String amount) => '$n people paid $amount';
  static String paymentTitle(String from, String to) => '$from paid $to';
  static const payment = 'Payment';
  static const possibleDuplicate = 'possible duplicate';
  static String amountUpTo(String max) => 'Enter an amount up to $max';
  static String amountDecimals(int digits) => switch (digits) {
    0 => 'Enter a whole amount, with no decimals',
    1 => 'Enter an amount with at most 1 decimal',
    _ => 'Enter an amount with at most $digits decimals',
  };
  static const amountUnreadable = 'Enter the amount as a number';
  static const notYetShared = 'Not yet shared';
  static const restore = 'Restore';
  static const deleted = 'deleted';
  static const someone = 'Someone';
  static const you = 'You';

  // Payment methods.
  static const upi = 'UPI';
  static const cash = 'Cash';
  static const bank = 'Bank';
  static const other = 'Other';
  static const paymentMethod = 'Payment method';

  // Suggested payments.
  static const suggestedPayments = 'Suggested payments';
  static const simplifyDebts = 'Simplify debts';
  static String pays(String from, String to) =>
      from == you ? 'You pay $to' : '$from pays $to';

  /// First name for sentences: "Priya Sharma" -> "Priya".
  static String firstName(String name) {
    final t = name.trim();
    final i = t.indexOf(RegExp(r'\s'));
    return i < 0 ? t : t.substring(0, i);
  }

  // Avatar.
  static const notOnSettleUp = 'not on Settle Up yet';

  // Add expense.
  static const amount = 'Amount';
  static const description = 'Description';
  static const indianRupees = 'Indian rupees';
  static const splitEqually = 'Equally';
  static const splitExact = 'Exact amounts';
  static const splitPercent = 'Percent';
  static const splitShares = 'Shares';
  static const splitAdjust = 'Adjust';
  static const splitMethod = 'Split method';
  static const notInThisExpense = 'not in this expense';
  static String leftToSplit(String amount) => '$amount left to split';
  static String tooMuch(String amount) => '$amount too much';
  static String changeCategory(String label) =>
      'Category: $label. Change category';

  // Before/after table.
  static const now = 'Now';
  static const after = 'After';
  static const balance = 'Balance';

  // Sync (never "offline").
  static const onThisPhone = 'On this phone';
  static String syncedAgo(String ago) => 'Synced $ago';
  static const synced = 'Synced';
  static const allShared = 'Everything is shared';
  static String changesToShare(int n) =>
      n == 1 ? '1 change to share' : '$n changes to share';
  static String lastSyncedWith(String peer, String ago) =>
      'Last synced with $peer $ago';
  static String lastSynced(String ago) => 'Last synced $ago';
  static const neverSynced = 'Not synced with another phone yet';
  static String syncingWith(String name) => 'Syncing with $name';
  static const syncing = 'Syncing';
  static const syncStopped = 'Sync stopped';
  static const syncStoppedBody = 'Nothing was lost. Try again when close by.';
  static const sync = 'Sync';
  static const openSync = 'Open sync';
  static const pair = 'Pair';
  static const thisPhone = 'This phone';
  static const nearbyPhones = 'Nearby phones';
  static const looking = 'Looking';
  static const unknownPhone = 'Unknown phone';
  static const wifi = 'Wi-Fi';
  static const bluetooth = 'Bluetooth';
  static String shares(String groups) => 'shares $groups';
  static const noSharedGroups = 'no shared groups';
  static String syncWith(String name) => 'Sync with $name';
  static String pairWith(String name) => 'Pair with $name';

  // Host card.
  static const makeVisible = 'Make this phone visible';
  static const friendsScan = 'Friends scan this to sync with you';
  static const orConnectTo = 'Or connect to';
  static const hotspot = 'Hotspot';
  static const qrLabel = 'QR code to sync with this phone';

  // Navigation.
  static const home = 'Home';
  static const activity = 'Activity';
  static const addExpense = 'Add expense';

  /// Screen-reader amount without plus/minus words.
  static String spokenAmount(int minor, String currency) =>
      MoneyFormat.spoken(minor, currency);
}
