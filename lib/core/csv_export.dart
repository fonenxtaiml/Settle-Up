// FROZEN CONTRACT (docs/SPEC.md section 5.10). Owner: core.
import 'ledger_state.dart';

abstract final class CsvExport {
  /// RFC 4180 CSV, CRLF line ends, UTF-8 (caller adds BOM if wanted).
  /// Columns: Date (yyyy-MM-dd, UTC), Description, Category, Cost (decimal
  /// with the currency's minor digits, '.' separator), Currency, then one
  /// column per active member (display name) holding paid - owed for that
  /// row. Payments included with Category "Payment". Deleted rows excluded.
  /// Rows sorted by date asc, then id.
  static String group(GroupState group) => throw UnimplementedError();
}
