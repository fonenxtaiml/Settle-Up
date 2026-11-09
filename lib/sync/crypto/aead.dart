// Per-frame AES-256-GCM (SPEC 8.2).
//
//   sealed := 0x01 | nonce:12 | ciphertext || tag:16
//   nonce  := 0x00000000 | counter:u64be   (per direction, from 0, +1/frame)
//
// The receiver requires counter == expected, which rejects replayed,
// dropped and reordered frames (the channel itself is ordered).
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol/codec.dart';

/// Bytes a sealed frame adds to the plain form: prefix + nonce + tag.
const int kSealOverhead = 1 + 12 + 16;

/// Decryption, nonce or counter failure. The session closes with
/// `authFailed`.
final class FrameAuthException implements Exception {
  const FrameAuthException(this.message);
  final String message;
  @override
  String toString() => 'FrameAuthException($message)';
}

/// Constant-time byte comparison (lengths are not secret).
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// One direction pair of AEAD state for an authenticated session. Not
/// safe for concurrent use: callers serialize [seal] and [open] calls (the
/// session does).
final class FrameCipher {
  FrameCipher({required List<int> sendKey, required List<int> receiveKey})
      : _sendKey = SecretKeyData(List<int>.of(sendKey)),
        _receiveKey = SecretKeyData(List<int>.of(receiveKey)) {
    if (sendKey.length != 32 || receiveKey.length != 32) {
      throw ArgumentError('AES-256-GCM keys must be 32 bytes');
    }
  }

  static final AesGcm _aes = AesGcm.with256bits(nonceLength: 12);

  /// Largest counter before the session must stop (never reached in
  /// practice; prevents nonce reuse on wrap).
  static const int maxCounter = 0x7FFFFFFFFFFFFFFF;

  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  int get sentFrames => _sendCounter;
  int get receivedFrames => _receiveCounter;

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  /// Encrypts [plain] (`type | flags | body`) into a sealed channel frame.
  Future<Uint8List> seal(Uint8List plain) async {
    if (_sendCounter >= maxCounter) {
      throw StateError('Frame counter exhausted');
    }
    final nonce = _nonce(_sendCounter++);
    final box = await _aes.encrypt(plain, secretKey: _sendKey, nonce: nonce);
    final out = Uint8List(kSealOverhead + box.cipherText.length);
    out[0] = FrameKind.sealed;
    out.setRange(1, 13, nonce);
    out.setRange(13, 13 + box.cipherText.length, box.cipherText);
    out.setRange(13 + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypts a sealed channel frame and returns the plain bytes. Throws
  /// [FrameAuthException] if the frame is not sealed, the nonce is not the
  /// next expected one, or authentication fails. A failed frame does not
  /// advance the counter, but the session must close anyway.
  Future<Uint8List> open(Uint8List frame) async {
    if (frame.length < kSealOverhead || frame[0] != FrameKind.sealed) {
      throw const FrameAuthException('Not a sealed frame');
    }
    final nonce = Uint8List.sublistView(frame, 1, 13);
    final view = ByteData.sublistView(nonce);
    if (view.getUint32(0) != 0 || view.getUint64(4) != _receiveCounter) {
      throw const FrameAuthException('Unexpected frame counter');
    }
    final cipherText = Uint8List.sublistView(frame, 13, frame.length - 16);
    final tag = Uint8List.sublistView(frame, frame.length - 16);
    try {
      final plain = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
        secretKey: _receiveKey,
      );
      _receiveCounter++;
      return plain is Uint8List ? plain : Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const FrameAuthException('Frame authentication failed');
    }
  }
}
