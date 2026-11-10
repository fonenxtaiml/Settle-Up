// Sharing a group as CSV, the same way from Settings and the group menu.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/csv_export.dart';
import '../../core/ledger_state.dart';
import '../strings.dart';
import 'common.dart';

/// Used when a group name has nothing a file name can keep ("🏖️").
const String kCsvFallbackName = 'settle-up-export';

/// "Goa trip.csv", "गोवा ट्रिप.csv"; characters that file systems or share
/// targets reject are dropped, and an empty result falls back to
/// [kCsvFallbackName]. Letters and digits of every script are kept.
String csvFileName(String title) {
  final kept = title
      .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N} _\-.()]', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      // A leading dot hides the file, also after a space (". .Goa trip").
      .replaceAll(RegExp(r'^[\s.]+'), '')
      .trim();
  final word = RegExp(r'[\p{L}\p{N}]', unicode: true);
  // The fallback is chosen after the cut: a first character longer than
  // the budget (a letter with a hundred combining marks) leaves nothing,
  // and the file must never be the hidden, nameless ".csv" (DATA-R4-02).
  final cut = _cut(kept, 80).trim();
  final base = word.hasMatch(cut) ? cut : kCsvFallbackName;
  return '$base.csv';
}

/// [s] cut to at most [units] UTF-16 units on a character boundary, so a
/// letter outside the BMP or a cluster is never split (DATA-R3-02).
String _cut(String s, int units) {
  if (s.length <= units) return s;
  final out = StringBuffer();
  for (final ch in s.characters) {
    if (out.length + ch.length > units) break;
    out.write(ch);
  }
  return out.toString();
}

/// The CSV bytes with a UTF-8 byte order mark, so Excel reads non-Latin
/// names and descriptions correctly.
Uint8List csvBytes(GroupState g) =>
    Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(CsvExport.group(g))]);

/// Opens the share sheet with [g] as "<title>.csv". A failure (no app can
/// take it, a platform error) is shown as copy, never thrown.
Future<void> shareGroupCsv(
  BuildContext context,
  GroupState g,
  String title,
) async {
  final name = csvFileName(title);
  await runGuarded(
    context,
    () => SharePlus.instance.share(
      ShareParams(
        subject: S.csvSubject(title),
        files: [XFile.fromData(csvBytes(g), mimeType: 'text/csv', name: name)],
        // XFile.fromData ignores its name on Android and iOS; this sets it.
        fileNameOverrides: [name],
      ),
    ),
  );
}
