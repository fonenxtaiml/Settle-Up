// BLE chunking (SPEC 8.7.2): one channel frame travels as a run of GATT
// writes (central -> peripheral) or notifications (peripheral -> central).
//
//   chunk := flags:u8 (bit0 FIRST, bit1 LAST) | seq:u8 | bytes
//
// `seq` counts chunks per direction modulo 256 and runs on across frames,
// so a lost, repeated or reordered chunk shows up as a gap. Any violation
// is fatal for the connection: the reassembler refuses everything after
// it, and the transport closes the channel.
//
// Pure Dart, no plugin types, unit tested in test/sync/bluetooth.
import 'dart:typed_data';

/// Largest frame on a BLE channel (SPEC 5.12: ble 16 KiB).
const int kBleMaxFrameBytes = 16 * 1024;

/// flags + seq.
const int kBleChunkHeaderBytes = 2;

const int kBleFlagFirst = 0x01;
const int kBleFlagLast = 0x02;

/// The smallest ATT payload a BLE link can have (default MTU 23 - 3).
const int kBleMinAttPayload = 20;

/// The largest ATT attribute value (and so write or notification).
const int kBleMaxAttPayload = 512;

/// The value bytes one write or notification carries at [mtu], as
/// `bluetooth_low_energy` computes `getMaximumWriteLength` and
/// `getMaximumNotifyLength`: `(mtu - 3).clamp(20, 512)`.
int bleAttPayloadForMtu(int mtu) =>
    (mtu - 3).clamp(kBleMinAttPayload, kBleMaxAttPayload);

/// A chunk stream that cannot be reassembled: the connection is unusable.
final class BleChunkException implements Exception {
  const BleChunkException(this.message);

  final String message;

  @override
  String toString() => 'BleChunkException: $message';
}

/// Splits outgoing frames into chunks. One instance per direction of one
/// connection (it owns the sequence counter).
final class BleChunker {
  BleChunker({this.maxFrameBytes = kBleMaxFrameBytes});

  final int maxFrameBytes;
  int _seq = 0;

  /// The sequence number the next chunk will carry.
  int get nextSeq => _seq;

  /// Chunks for [frame], each at most [attPayload] bytes (header included).
  /// [attPayload] is the write or notify length the link allows; it must
  /// leave room for at least one data byte.
  List<Uint8List> split(Uint8List frame, {required int attPayload}) {
    if (attPayload <= kBleChunkHeaderBytes) {
      throw ArgumentError.value(attPayload, 'attPayload', 'too small');
    }
    if (frame.length > maxFrameBytes) {
      throw ArgumentError(
        'Frame of ${frame.length} bytes > $maxFrameBytes',
      );
    }
    final room = attPayload - kBleChunkHeaderBytes;
    final chunks = <Uint8List>[];
    var offset = 0;
    do {
      final end = offset + room < frame.length ? offset + room : frame.length;
      final chunk = Uint8List(kBleChunkHeaderBytes + end - offset);
      var flags = 0;
      if (offset == 0) flags |= kBleFlagFirst;
      if (end == frame.length) flags |= kBleFlagLast;
      chunk[0] = flags;
      chunk[1] = _seq;
      chunk.setRange(kBleChunkHeaderBytes, chunk.length, frame, offset);
      _seq = (_seq + 1) & 0xff;
      chunks.add(chunk);
      offset = end;
    } while (offset < frame.length);
    return chunks;
  }

  /// How many chunks a frame of [frameBytes] needs at [attPayload].
  static int chunkCount(int frameBytes, {required int attPayload}) {
    final room = attPayload - kBleChunkHeaderBytes;
    if (frameBytes == 0) return 1;
    return (frameBytes + room - 1) ~/ room;
  }
}

/// Rebuilds frames from incoming chunks. One instance per direction of one
/// connection.
final class BleReassembler {
  BleReassembler({this.maxFrameBytes = kBleMaxFrameBytes});

  final int maxFrameBytes;

  int _expected = 0;
  BytesBuilder? _partial;
  BleChunkException? _failure;

  /// The sequence number the next chunk must carry.
  int get expectedSeq => _expected;

  /// Whether a frame is half received.
  bool get inFrame => _partial != null;

  /// Set once a violation was seen; every later [add] rethrows it.
  BleChunkException? get failure => _failure;

  /// Feeds one chunk. Returns the frame it completes, or null when more
  /// chunks are needed. Throws [BleChunkException] on a short chunk, a
  /// sequence gap, a chunk out of place (continuation without FIRST, FIRST
  /// inside a frame) or a frame over [maxFrameBytes].
  Uint8List? add(Uint8List chunk) {
    final failed = _failure;
    if (failed != null) throw failed;
    if (chunk.length < kBleChunkHeaderBytes) {
      return _fail('Chunk of ${chunk.length} bytes has no header');
    }
    final flags = chunk[0];
    final seq = chunk[1];
    if (seq != _expected) {
      return _fail('Sequence gap: got $seq, expected $_expected');
    }
    _expected = (_expected + 1) & 0xff;

    final first = (flags & kBleFlagFirst) != 0;
    final last = (flags & kBleFlagLast) != 0;
    var partial = _partial;
    if (first) {
      if (partial != null) return _fail('FIRST chunk inside a frame');
      partial = _partial = BytesBuilder(copy: false);
    } else if (partial == null) {
      return _fail('Continuation chunk without a FIRST chunk');
    }
    final data = Uint8List.sublistView(chunk, kBleChunkHeaderBytes);
    if (partial.length + data.length > maxFrameBytes) {
      return _fail(
        'Frame over $maxFrameBytes bytes (${partial.length + data.length})',
      );
    }
    // The caller may reuse its buffer: keep a copy.
    partial.add(Uint8List.fromList(data));
    if (!last) return null;
    _partial = null;
    return partial.takeBytes();
  }

  Never _fail(String message) {
    _partial = null;
    throw _failure = BleChunkException(message);
  }
}
