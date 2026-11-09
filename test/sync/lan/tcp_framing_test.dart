// LAN framing (SPEC 8.7.2, 11.3): `len:u32be | frame`, reassembled across
// split and coalesced reads; len 0 or > 1 MiB closes the connection.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/transport/lan/tcp_framing.dart';

Uint8List bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List prefix(int length) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, length);
  return b;
}

Uint8List concat(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  parts.forEach(out.add);
  return out.toBytes();
}

/// A connected (client, server) socket pair on 127.0.0.1.
Future<(Socket, Socket)> socketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final other = await accepted;
  await server.close();
  return (client, other);
}

void main() {
  group('encodeLanFrame', () {
    test('writes a big-endian u32 length then the frame', () {
      final out = encodeLanFrame(Uint8List.fromList([7, 8, 9]));
      expect(out, [0, 0, 0, 3, 7, 8, 9]);
      final big = encodeLanFrame(bytes(70000));
      expect(big.sublist(0, 4), [0, 1, 0x11, 0x70]);
      expect(big.length, 70004);
    });

    test('rejects empty and oversize frames', () {
      expect(() => encodeLanFrame(Uint8List(0)), throwsArgumentError);
      expect(
        () => encodeLanFrame(Uint8List(kLanMaxFrameBytes + 1)),
        throwsArgumentError,
      );
      expect(encodeLanFrame(Uint8List(kLanMaxFrameBytes)).length,
          kLanMaxFrameBytes + 4);
      expect(
        () => encodeLanFrame(Uint8List(11), maxFrameBytes: 10),
        throwsArgumentError,
      );
    });
  });

  group('LanFrameDecoder', () {
    final frames = [bytes(1, 1), bytes(300, 2), bytes(5, 3), bytes(70000, 4)];
    final wire = concat([for (final f in frames) encodeLanFrame(f)]);

    test('coalesced: many frames in one read', () {
      final d = LanFrameDecoder();
      expect(d.add(wire), frames);
      expect(d.bufferedBytes, 0);
    });

    test('split: one byte per read, including inside the prefix', () {
      final d = LanFrameDecoder();
      final out = <Uint8List>[];
      for (final b in wire) {
        out.addAll(d.add([b]));
      }
      expect(out, frames);
      expect(d.bufferedBytes, 0);
    });

    test('random chunking never changes the frames', () {
      final r = Random(42);
      for (var round = 0; round < 200; round++) {
        final d = LanFrameDecoder();
        final out = <Uint8List>[];
        var i = 0;
        while (i < wire.length) {
          final n = min(1 + r.nextInt(r.nextBool() ? 8 : 100000), wire.length - i);
          out.addAll(d.add(Uint8List.sublistView(wire, i, i + n)));
          i += n;
        }
        expect(out, frames, reason: 'round $round');
      }
    });

    test('a read that ends a frame and starts the next', () {
      final d = LanFrameDecoder();
      final a = encodeLanFrame(bytes(10, 5));
      final b = encodeLanFrame(bytes(20, 6));
      final both = concat([a, b]);
      expect(d.add(both.sublist(0, a.length + 2)), [bytes(10, 5)]);
      expect(d.bufferedBytes, 2);
      expect(d.add(both.sublist(a.length + 2)), [bytes(20, 6)]);
    });

    test('frames do not alias the input buffer', () {
      final d = LanFrameDecoder();
      final input = encodeLanFrame(Uint8List.fromList([1, 2, 3]));
      final out = d.add(input).single;
      input.fillRange(0, input.length, 0);
      expect(out, [1, 2, 3]);
    });

    test('oversize length throws and poisons the decoder', () {
      final d = LanFrameDecoder();
      expect(
        () => d.add(prefix(kLanMaxFrameBytes + 1)),
        throwsA(isA<FrameLengthException>()
            .having((e) => e.length, 'length', kLanMaxFrameBytes + 1)),
      );
      expect(() => d.add(encodeLanFrame(bytes(3))),
          throwsA(isA<FrameLengthException>()));
    });

    test('frames before a bad prefix in the same read are kept', () {
      final d = LanFrameDecoder();
      final out = d.add(concat([encodeLanFrame(bytes(4, 8)), prefix(0)]));
      expect(out, [bytes(4, 8)]);
      expect(d.failure, isA<FrameLengthException>());
      expect(() => d.add([1]), throwsA(isA<FrameLengthException>()));
    });

    test('a 1 MiB frame is accepted, len 0 is not', () {
      expect(LanFrameDecoder().add(encodeLanFrame(Uint8List(kLanMaxFrameBytes))),
          hasLength(1));
      expect(() => LanFrameDecoder().add(prefix(0)),
          throwsA(isA<FrameLengthException>()));
    });

    test('oversize is detected from the prefix alone', () {
      final d = LanFrameDecoder(maxFrameBytes: 100);
      expect(d.add([0, 0]), isEmpty);
      expect(() => d.add([0, 101]), throwsA(isA<FrameLengthException>()));
    });
  });

  group('parseHostPort / formatHostPort', () {
    test('IPv4, bracketed IPv6, bare hosts', () {
      expect(parseHostPort('192.168.1.5:52741'), (host: '192.168.1.5', port: 52741));
      expect(parseHostPort('[fe80::1]:9000'), (host: 'fe80::1', port: 9000));
      expect(parseHostPort('fe80::1', defaultPort: 1), (host: 'fe80::1', port: 1));
      expect(parseHostPort('10.0.0.1', defaultPort: 52741),
          (host: '10.0.0.1', port: 52741));
      expect(parseHostPort('10.0.0.1'), isNull);
      expect(parseHostPort('10.0.0.1:0'), isNull);
      expect(parseHostPort('10.0.0.1:70000'), isNull);
      expect(parseHostPort('[::1'), isNull);
      expect(parseHostPort(''), isNull);
      expect(formatHostPort(InternetAddress('10.1.2.3'), 5), '10.1.2.3:5');
      expect(formatHostPort(InternetAddress('::1'), 5), '[::1]:5');
    });
  });

  group('SocketFrameChannel over real sockets', () {
    late Socket client;
    late Socket server;

    setUp(() async {
      (client, server) = await socketPair();
    });

    tearDown(() {
      client.destroy();
      server.destroy();
    });

    test('frames written in one coalesced write arrive one by one', () async {
      final ch = SocketFrameChannel(server, peerAddress: 'client');
      final frames = [bytes(3, 1), bytes(4000, 2), bytes(1, 3)];
      client.add(concat([for (final f in frames) encodeLanFrame(f)]));
      await client.flush();
      expect(await ch.frames.take(3).toList(), frames);
      await ch.close();
    });

    test('a frame written one byte at a time arrives whole', () async {
      final ch = SocketFrameChannel(server, peerAddress: 'client');
      final frame = bytes(64, 9);
      final got = ch.frames.first;
      for (final b in encodeLanFrame(frame)) {
        client.add([b]);
        await client.flush();
      }
      expect(await got, frame);
      await ch.close();
    });

    test('send/receive both ways, order kept under concurrent sends', () async {
      final a = SocketFrameChannel(client, peerAddress: 'server');
      final b = SocketFrameChannel(server, peerAddress: 'client');
      final sent = [for (var i = 0; i < 50; i++) bytes(1 + i * 997, i)];
      final received = b.frames.take(sent.length).toList();
      await Future.wait([for (final f in sent) a.send(f)]);
      expect(await received, sent);

      final back = a.frames.first;
      await b.send(Uint8List.fromList([42]));
      expect(await back, [42]);
      await a.close();
      await b.close();
    });

    test('a 1 MiB frame crosses the socket', () async {
      final a = SocketFrameChannel(client, peerAddress: 'server');
      final b = SocketFrameChannel(server, peerAddress: 'client');
      final big = bytes(kLanMaxFrameBytes, 77);
      final got = b.frames.first;
      await a.send(big);
      expect(await got, big);
      await a.close();
      await b.close();
    });

    test('send checks size and state', () async {
      final a = SocketFrameChannel(client, peerAddress: 'server');
      await expectLater(
        a.send(Uint8List(kLanMaxFrameBytes + 1)),
        throwsArgumentError,
      );
      await a.close();
      await expectLater(a.send(Uint8List(1)), throwsStateError);
      expect(a.isClosed, isTrue);
    });

    test('oversize length from the peer errors the stream and closes',
        () async {
      final ch = SocketFrameChannel(server, peerAddress: 'client');
      final events = <Object>[];
      final done = Completer<void>();
      ch.frames.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );
      client.add(encodeLanFrame(bytes(2)));
      client.add(prefix(kLanMaxFrameBytes + 1));
      await client.flush();
      await done.future.timeout(const Duration(seconds: 5));
      expect(events, hasLength(2));
      expect(events[0], bytes(2));
      expect(events[1], isA<FrameLengthException>());
      // The server side closed the socket: the client sees end of stream.
      await client.drain<void>().timeout(const Duration(seconds: 5));
      await expectLater(ch.send(Uint8List(1)), throwsStateError);
    });

    test('zero length from the peer closes', () async {
      final ch = SocketFrameChannel(server, peerAddress: 'client');
      final err = ch.frames.toList();
      client.add(prefix(0));
      await client.flush();
      await expectLater(err, throwsA(isA<FrameLengthException>()));
    });

    test('peer close ends the stream; local close ends the peer', () async {
      final a = SocketFrameChannel(client, peerAddress: 'server');
      final b = SocketFrameChannel(server, peerAddress: 'client');
      final bDone = b.frames.toList();
      await a.send(Uint8List.fromList([1]));
      await a.close();
      expect(await bDone.timeout(const Duration(seconds: 5)), [
        [1],
      ]);
      await b.close();
    });

    test('frames sent right before close still arrive', () async {
      final a = SocketFrameChannel(client, peerAddress: 'server');
      final b = SocketFrameChannel(server, peerAddress: 'client');
      final all = b.frames.toList();
      unawaited(a.send(Uint8List.fromList([1])));
      unawaited(a.send(Uint8List.fromList([2])));
      await a.close();
      expect(await all.timeout(const Duration(seconds: 5)), [
        [1],
        [2],
      ]);
    });

    test('nothing is lost while the listener starts late', () async {
      final b = SocketFrameChannel(server, peerAddress: 'client');
      client.add(encodeLanFrame(Uint8List.fromList([5])));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await b.frames.first, [5]);
    });
  });
}
