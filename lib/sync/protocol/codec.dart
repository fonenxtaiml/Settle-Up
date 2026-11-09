// Frame codec (SPEC 8.2), identical on every transport.
//
//   channel frame := 0x00 plain | 0x01 sealed
//   plain         := type:u8 | flags:u8 | body   (flags bit0 = body is gzip)
//   body          := UTF-8 JSON object, gzipped when the JSON is > 1024 bytes
//
// Sealing (0x01) lives in crypto/aead.dart; this file handles the plain form.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'messages.dart';

/// Channel frame prefix bytes.
abstract final class FrameKind {
  static const int plain = 0x00;
  static const int sealed = 0x01;
}

/// `flags` bit 0: the body is gzip compressed.
const int kFlagGzip = 0x01;

/// JSON bodies larger than this are gzipped (SPEC 8.2).
const int kGzipThreshold = 1024;

/// Upper bound on a decompressed body (guards against gzip bombs). The
/// sender keeps OPS JSON under 0.75 x maxFrame (1 MiB on LAN), so 8 MiB is
/// generous.
const int kMaxDecompressedBytes = 8 << 20;

abstract final class FrameCodec {
  /// `type | flags | body` for [message].
  static Uint8List encodePlain(SyncMessage message) {
    final json = utf8.encode(jsonEncode(message.toJson()));
    var flags = 0;
    List<int> body = json;
    if (json.length > kGzipThreshold) {
      body = gzip.encode(json);
      flags |= kFlagGzip;
    }
    final out = Uint8List(2 + body.length);
    out[0] = message.type.code;
    out[1] = flags;
    out.setRange(2, out.length, body);
    return out;
  }

  /// Parses `type | flags | body`. Throws [ProtocolException]: `bad_frame`
  /// for an unknown type, unknown flags, bad gzip, bad UTF-8 or JSON that is
  /// not an object; `bad_op` for a malformed op inside OPS.
  static SyncMessage decodePlain(Uint8List plain) {
    if (plain.length < 2) {
      throw const ProtocolException(ErrorCodes.badFrame, 'short frame');
    }
    final type = MessageType.fromCode(plain[0]);
    if (type == null) {
      throw ProtocolException(ErrorCodes.badFrame, 'unknown type ${plain[0]}');
    }
    final flags = plain[1];
    if (flags & ~kFlagGzip != 0) {
      throw ProtocolException(ErrorCodes.badFrame, 'unknown flags $flags');
    }
    var body = Uint8List.sublistView(plain, 2);
    if (flags & kFlagGzip != 0) body = _gunzip(body);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const ProtocolException(ErrorCodes.badFrame, 'bad JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const ProtocolException(ErrorCodes.badFrame, 'body not an object');
    }
    return SyncMessage.fromJson(type, json);
  }

  /// A complete plain channel frame: `0x00 | type | flags | body`.
  static Uint8List plainFrame(SyncMessage message) {
    final plain = encodePlain(message);
    final out = Uint8List(1 + plain.length);
    out[0] = FrameKind.plain;
    out.setRange(1, out.length, plain);
    return out;
  }

  /// Parses a plain channel frame (`0x00 | plain`).
  static SyncMessage decodePlainFrame(Uint8List frame) {
    if (frame.isEmpty || frame[0] != FrameKind.plain) {
      throw const ProtocolException(ErrorCodes.badFrame, 'not a plain frame');
    }
    return decodePlain(Uint8List.sublistView(frame, 1));
  }

  static Uint8List _gunzip(Uint8List data) {
    final out = BytesBuilder(copy: false);
    final limited = _LimitedSink(out);
    try {
      final decoder = gzip.decoder.startChunkedConversion(limited);
      decoder.add(data);
      decoder.close();
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw const ProtocolException(ErrorCodes.badFrame, 'bad gzip');
    }
    return out.takeBytes();
  }
}

/// Collects decompressed bytes and aborts past [kMaxDecompressedBytes].
final class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this._out);
  final BytesBuilder _out;

  @override
  void add(List<int> chunk) {
    if (_out.length + chunk.length > kMaxDecompressedBytes) {
      throw const ProtocolException(ErrorCodes.tooLarge, 'body too large');
    }
    _out.add(chunk);
  }

  @override
  void close() {}
}
