// FROZEN CONTRACT (docs/SPEC.md section 5.10). Owner: core.
import 'categories.dart';
import 'ids.dart';
import 'ledger_state.dart';
import 'member_order.dart';
import 'models.dart';
import 'money.dart';

abstract final class CsvExport {
  /// RFC 4180 CSV, CRLF line ends, UTF-8 (caller adds BOM if wanted).
  /// Columns: Date (yyyy-MM-dd, UTC), Description, Category, Cost (decimal
  /// with the currency's minor digits, '.' separator), Currency, then one
  /// column per active member (display name) holding paid - owed for that
  /// row. Payments included with Category "Payment". Deleted rows excluded.
  /// Rows sorted by date asc, then id.
  ///
  /// Details: merged members are counted in the column of the member they
  /// were merged into. A removed member who still appears in an exported
  /// row gets a column after the active members, so every row's member
  /// columns sum to zero. Every record, the last included, ends with CRLF.
  /// Text cells that a spreadsheet would run as a formula (leading `=`, `+`,
  /// `-`, `@`, tab or CR) are prefixed with `'`.
  static String group(GroupState group) {
    final rows = group.liveExpenses
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

    final columns = group.activeMembers;
    final active = {for (final m in columns) m.id};
    final extra = <Member>[];
    for (final e in rows) {
      for (final id in {...e.money.paid.keys, ...e.money.owed.keys}) {
        final r = group.resolve(id);
        if (active.contains(r) || extra.any((m) => m.id == r)) continue;
        final m = group.members[r];
        if (m != null && _impact(group, e, r) != 0) extra.add(m);
      }
    }
    extra.sort(compareMembersByName);
    columns.addAll(extra);

    final out = StringBuffer();
    void record(List<String> cells) {
      out
        ..write(cells.map(_escape).join(','))
        ..write('\r\n');
    }

    record([
      'Date',
      'Description',
      'Category',
      'Cost',
      'Currency',
      for (final m in columns) _text(m.displayName),
    ]);
    for (final e in rows) {
      final currency = Currencies.of(e.money.currency);
      record([
        _date(e.date),
        _text(_description(group, e)),
        e.isPayment ? 'Payment' : Categories.byId(e.category).label,
        _decimal(e.money.total, currency),
        // The code comes from synced ops, so it is untrusted text too.
        _text(e.money.currency),
        for (final m in columns) _decimal(_impact(group, e, m.id), currency),
      ]);
    }
    return out.toString();
  }

  /// paid - owed of every member that resolves to [member].
  static int _impact(GroupState group, Expense e, MemberId member) {
    var v = 0;
    e.money.paid.forEach((m, x) {
      if (group.resolve(m) == member) v += x;
    });
    e.money.owed.forEach((m, x) {
      if (group.resolve(m) == member) v -= x;
    });
    return v;
  }

  static String _description(GroupState group, Expense e) {
    if (!e.isPayment || e.description.isNotEmpty) return e.description;
    String name(MemberId id) =>
        group.members[group.resolve(id)]?.displayName ?? id;
    return '${name(e.payer)} paid ${name(e.receiver)}';
  }

  static String _date(DateTime d) {
    final u = d.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}';
  }

  /// Integer minor units to a plain decimal string, no grouping.
  static String _decimal(int minor, Currency currency) {
    final sign = minor < 0 ? '-' : '';
    final abs = minor.abs();
    if (currency.minorDigits == 0) return '$sign$abs';
    final major = abs ~/ currency.minorPerMajor;
    final frac = (abs % currency.minorPerMajor).toString().padLeft(
      currency.minorDigits,
      '0',
    );
    return '$sign$major.$frac';
  }

  static String _text(String s) {
    if (s.isEmpty) return s;
    const risky = {'=', '+', '-', '@', '\t', '\r'};
    return risky.contains(s[0]) ? "'$s" : s;
  }

  static String _escape(String cell) {
    if (cell.contains(RegExp('[",\r\n]'))) {
      return '"${cell.replaceAll('"', '""')}"';
    }
    return cell;
  }
}
