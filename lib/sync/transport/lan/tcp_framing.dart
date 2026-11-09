// TCP framing for the LAN transport (SPEC 8.7.2): every channel frame goes
// on the socket as `len:u32be | channel frame`. A length of 0 or above the
// 1 MiB limit is a protocol violation and closes the connection. Frames are
// reassembled across reads, so a read may carry part of a frame, several
// frames, or both.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/models.dart';
import '../transport.dart';

/// Largest channel frame on LAN (SPEC 5.12: lan 1 MiB).
const int kLanMaxFrameBytes = 1 << 20;

/// Bytes in the length prefix.
const int kLanLengthPrefixBytes = 4;

/// A length prefix that breaks the framing rules.
final class FrameLengthException implements Exception {
  const FrameLengthException(this.length, this.maxFrameBytes);

  final int length;
  final int maxFrameBytes;

  @override
  String toString() => length == 0
      ? 'FrameLengthException: empty frame'
      : 'FrameLengthException: frame of $length bytes > $maxFrameBytes';
}

/// Returns `len:u32be | frame` as one buffer.
Uint8List encodeLanFrame(
  Uint8List frame, {
  int maxFrameBytes = kLanMaxFrameBytes,
}) {
  if (frame.isEmpty) {
    throw ArgumentError.value(frame.length, 'frame', 'Empty frame');
  }
  if (frame.length > maxFrameBytes) {
    throw ArgumentError.value(
      frame.length,
      'frame',
      'Frame of ${frame.length} bytes > $maxFrameBytes',
    );
  }
  final out = Uint8List(kLanLengthPrefixBytes + frame.length);
  ByteData.sublistView(out).setUint32(0, frame.length);
  out.setRange(kLanLengthPrefixBytes, out.length, frame);
  return out;
}

/// Incremental decoder: feed it socket reads, get whole frames back.
///
/// A bad length prefix poisons the decoder, because the byte stream can no
/// longer be trusted: [add] throws [FrameLengthException] when it completed
/// no frame before the bad prefix, and otherwise returns those frames and
/// sets [failure] (every later [add] throws).
final class LanFrameDecoder {
  LanFrameDecoder({this.maxFrameBytes = kLanMaxFrameBytes});

  final int maxFrameBytes;

  final List<Uint8List> _chunks = [];
  int _buffered = 0;

  /// Offset into `_chunks.first` that is already consumed.
  int _offset = 0;

  /// Length of the frame being assembled, or -1 while reading the prefix.
  int _expected = -1;
  FrameLengthException? _failure;

  /// Bytes held that do not form a whole frame yet.
  int get bufferedBytes => _buffered;

  /// Set once a bad length prefix was seen.
  FrameLengthException? get failure => _failure;

  /// Appends [data] and returns every frame it completes, in order.
  List<Uint8List> add(List<int> data) {
    final failure = _failure;
    if (failure != null) throw failure;
    if (data.isNotEmpty) {
      _chunks.add(data is Uint8List ? data : Uint8List.fromList(data));
      _buffered += data.length;
    }
    final out = <Uint8List>[];
    while (true) {
      if (_expected < 0) {
        if (_buffered < kLanLengthPrefixBytes) break;
        final prefix = ByteData.sublistView(_take(kLanLengthPrefixBytes));
        final length = prefix.getUint32(0);
        if (length == 0 || length > maxFrameBytes) {
          _clear();
          final failure =
              _failure = FrameLengthException(length, maxFrameBytes);
          if (out.isEmpty) throw failure;
          return out;
        }
        _expected = length;
      }
      if (_buffered < _expected) break;
      out.add(_take(_expected));
      _expected = -1;
    }
    return out;
  }

  /// Removes and returns the next [n] buffered bytes (n <= _buffered).
  Uint8List _take(int n) {
    final first = _chunks.first;
    if (first.length - _offset >= n) {
      // Fast path: inside one read. Copy, so the frame never aliases a
      // buffer the socket may reuse.
      final out = Uint8List.fromList(
        Uint8List.sublistView(first, _offset, _offset + n),
      );
      _advance(n);
      return out;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final chunk = _chunks.first;
      final available = chunk.length - _offset;
      final count = available < n - filled ? available : n - filled;
      out.setRange(filled, filled + count, chunk, _offset);
      filled += count;
      _advance(count);
    }
    return out;
  }

  void _advance(int n) {
    _offset += n;
    _buffered -= n;
    while (_chunks.isNotEmpty && _offset >= _chunks.first.length) {
      _offset -= _chunks.first.length;
      _chunks.removeAt(0);
    }
  }

  void _clear() {
    _chunks.clear();
    _buffered = 0;
    _offset = 0;
    _expected = -1;
  }
}

/// A [FrameChannel] over a connected TCP [Socket].
///
/// [frames] is done when the peer closes, and errors (then is done) on a
/// socket error or a framing violation, which also closes the socket.
/// [send] calls are queued, so concurrent sends keep their order and never
/// overlap a pending flush.
final class SocketFrameChannel implements FrameChannel {
  /// Wraps [socket]. Some bytes may have been read from the socket
  /// before (e.g. while waiting for the first frame of an inbound
  /// connection); [decoder] holds any partial frame read after them, and
  /// [pendingFrames] are delivered first. [subscription], when given, is
  /// the socket's existing listener, paused exactly once, which the
  /// channel takes over.
  SocketFrameChannel(
    this._socket, {
    required this.peerAddress,
    this.maxFrameBytes = kLanMaxFrameBytes,
    LanFrameDecoder? decoder,
    List<Uint8List> pendingFrames = const [],
    StreamSubscription<Uint8List>? subscription,
  }) : _decoder = decoder ?? LanFrameDecoder(maxFrameBytes: maxFrameBytes) {
    _frames = StreamController<Uint8List>(
      onListen: () => _subscription?.resume(),
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      // Cancelling stops reading; the socket stays open for sending
      // until [close].
      onCancel: () async {
        final sub = _subscription;
        _subscription = null;
        await sub?.cancel();
      },
    );
    pendingFrames.forEach(_frames.add);
    // Paused (once) until [frames] is listened to.
    final sub = subscription ?? (_socket.listen(null)..pause());
    sub
      ..onData(_onData)
      ..onError(_onError)
      ..onDone(_onDone);
    _subscription = sub;
  }

  final Socket _socket;
  final LanFrameDecoder _decoder;
  StreamSubscription<Uint8List>? _subscription;
  late final StreamController<Uint8List> _frames;
  Future<void> _sendTail = Future.value();
  bool _closed = false;
  bool _destroyed = false;
  Future<void>? _closing;

  @override
  TransportKind get kind => TransportKind.lan;

  @override
  final String peerAddress;

  @override
  final int maxFrameBytes;

  /// Whether [close] ran or the connection ended.
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> send(Uint8List frame) {
    if (_closed) return Future.error(StateError('Channel closed'));
    final Uint8List bytes;
    try {
      bytes = encodeLanFrame(frame, maxFrameBytes: maxFrameBytes);
    } on ArgumentError catch (e) {
      return Future.error(e);
    }
    final done = _sendTail.then((_) async {
      // Frames queued before close() still go out; only a dead socket
      // stops them.
      if (_destroyed) throw StateError('Channel closed');
      _socket.add(bytes);
      await _socket.flush();
    });
    // Keep the queue going after a failed send; the caller sees the error.
    _sendTail = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  @override
  Future<void> close() => _shutdown();

  void _onData(Uint8List data) {
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(data);
    } on FrameLengthException catch (e) {
      _fail(e);
      return;
    }
    for (final f in frames) {
      if (!_frames.isClosed) _frames.add(f);
    }
    final failure = _decoder.failure;
    if (failure != null) _fail(failure);
  }

  void _onError(Object error, [StackTrace? st]) => _fail(error, st);

  void _onDone() {
    if (!_frames.isClosed) unawaited(_frames.close());
    unawaited(_shutdown());
  }

  void _fail(Object error, [StackTrace? st]) {
    if (!_frames.isClosed) {
      _frames.addError(error, st);
      unawaited(_frames.close());
    }
    unawaited(_shutdown());
  }

  Future<void> _shutdown() => _closing ??= _doShutdown();

  Future<void> _doShutdown() async {
    _closed = true;
    try {
      // Let queued frames reach the OS first (BYE, ERROR), but never hang
      // on a peer that stopped reading.
      await _sendTail.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Peer stopped reading: drop what is queued.
    }
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already gone.
    }
    _destroyed = true;
    _socket.destroy();
    if (!_frames.isClosed) {
      // Nobody may ever drain it after a local close; do not wait.
      unawaited(_frames.close());
    }
  }
}

/// `host:port` for [address] (IPv6 bracketed, SPEC 5.12).
String formatHostPort(InternetAddress address, int port) =>
    address.type == InternetAddressType.IPv6
        ? '[${address.address}]:$port'
        : '${address.address}:$port';

/// Parses `host:port`, `[v6]:port` or a bare host (port [defaultPort]).
/// Returns null when [value] is not one of those.
({String host, int port})? parseHostPort(String value, {int? defaultPort}) {
  final v = value.trim();
  if (v.isEmpty) return null;
  String host;
  String? portText;
  if (v.startsWith('[')) {
    final end = v.indexOf(']');
    if (end < 0) return null;
    host = v.substring(1, end);
    final rest = v.substring(end + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      portText = rest.substring(1);
    }
  } else {
    final colon = v.lastIndexOf(':');
    if (colon >= 0 && v.indexOf(':') == colon) {
      host = v.substring(0, colon);
      portText = v.substring(colon + 1);
    } else if (colon >= 0) {
      // Several colons without brackets: a bare IPv6 address.
      host = v;
    } else {
      host = v;
    }
  }
  if (host.isEmpty) return null;
  final int port;
  if (portText == null) {
    if (defaultPort == null) return null;
    port = defaultPort;
  } else {
    final parsed = int.tryParse(portText);
    if (parsed == null || parsed < 1 || parsed > 65535) return null;
    port = parsed;
  }
  return (host: host, port: port);
}
