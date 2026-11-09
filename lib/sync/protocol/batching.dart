// OPS batching (SPEC 8.5): add ops to a batch until the encoded JSON would
// exceed 0.75 x maxFrame or 500 ops. If a sealed frame still exceeds
// maxFrame, the session splits the batch in half and retries.
import 'dart:convert';

import '../../core/ids.dart';
import '../../core/ops.dart';
import 'messages.dart';

/// At most this many un-ACKed OPS batches in flight per session.
const int kBatchWindow = 4;

/// Fraction of the negotiated frame size an OPS JSON body may fill.
const double kBatchFill = 0.75;

/// Upper bound for the OPS envelope around the op list
/// (`{"g":..,"batch":..,"total":..,"ops":[],"more":false}`).
const int _envelopeBytes = 96 + kMaxIdLength;

/// UTF-8 length of the op's wire JSON.
int opJsonBytes(Operation op) => utf8.encode(jsonEncode(op.toJson())).length;

/// Splits [ops] (already in send order) into batches for [maxFrame].
/// A single op larger than the budget gets a batch of its own; the session
/// then decides whether it fits at all (`ERROR too_large`).
List<List<Operation>> planBatches(
  List<Operation> ops,
  int maxFrame, {
  int maxOps = kMaxOpsPerBatch,
}) {
  final budget = (maxFrame * kBatchFill).floor() - _envelopeBytes;
  final out = <List<Operation>>[];
  var current = <Operation>[];
  var size = 0;
  for (final op in ops) {
    final n = opJsonBytes(op) + 1; // + separating comma
    if (current.isNotEmpty && (size + n > budget || current.length >= maxOps)) {
      out.add(current);
      current = <Operation>[];
      size = 0;
    }
    current.add(op);
    size += n;
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}

/// A planned batch waiting to be sent.
final class PendingBatch {
  PendingBatch(this.groupId, this.ops);
  final GroupId groupId;
  final List<Operation> ops;

  /// Two halves, for a batch whose sealed frame was too large.
  (PendingBatch, PendingBatch) split() {
    final mid = ops.length ~/ 2;
    return (
      PendingBatch(groupId, ops.sublist(0, mid)),
      PendingBatch(groupId, ops.sublist(mid)),
    );
  }
}
