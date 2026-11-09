// BleChunker / BleReassembler (SPEC 11.3): chunk and reassemble at MTU 23,
// 185 and 517; the sequence number wraps at 256; a missing, repeated or
// misplaced chunk is an error that poisons the connection.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';

Uint8List bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Feeds every chunk, returns the frames completed.
List<Uint8List> feed(BleReassembler r, Iterable<Uint8List> chunks) => [
      for (final c in chunks) ?r.add(c),
    ];

void main() {
  group('ATT payload per MTU', () {
    test('matches bluetooth_low_energy: (mtu - 3) clamped to 20..512', () {
      expect(bleAttPayloadForMtu(23), 20);
      expect(bleAttPayloadForMtu(185), 182);
      expect(bleAttPayloadForMtu(517), 512);
      expect(bleAttPayloadForMtu(10), 20);
    });
  });

  for (final mtu in [23, 185, 517]) {
    group('MTU $mtu', () {
      final att = bleAttPayloadForMtu(mtu);

      test('every chunk fits one write and carries a header', () {
        final chunks = BleChunker().split(bytes(5000), attPayload: att);
        expect(chunks, isNotEmpty);
        for (final c in chunks) {
          expect(c.length, lessThanOrEqualTo(att));
          expect(c.length, greaterThan(kBleChunkHeaderBytes));
        }
        expect(chunks.length,
            BleChunker.chunkCount(5000, attPayload: att));
        expect(chunks.first[0] & kBleFlagFirst, kBleFlagFirst);
        expect(chunks.last[0] & kBleFlagLast, kBleFlagLast);
        for (final c in chunks.skip(1).take(chunks.length - 2)) {
          expect(c[0], 0, reason: 'middle chunks carry no flags');
        }
      });

      test('round trips frames from 0 bytes to the 16 KiB cap', () {
        final chunker = BleChunker();
        final reassembler = BleReassembler();
        final sizes = [0, 1, att - 2, att - 1, att, 2 * (att - 2), 1000,
            kBleMaxFrameBytes - 1, kBleMaxFrameBytes];
        for (final (i, n) in sizes.indexed) {
          final frame = bytes(n, i);
          final out = feed(reassembler, chunker.split(frame, attPayload: att));
          expect(out, hasLength(1), reason: 'size $n');
          expect(out.single, frame, reason: 'size $n');
        }
        expect(reassembler.inFrame, isFalse);
        expect(reassembler.expectedSeq, chunker.nextSeq);
      });

      test('random frames in a row keep their boundaries', () {
        final r = Random(mtu);
        final chunker = BleChunker();
        final reassembler = BleReassembler();
        final frames = [
          for (var i = 0; i < 60; i++) bytes(r.nextInt(3000), i),
        ];
        final chunks = [
          for (final f in frames) ...chunker.split(f, attPayload: att),
        ];
        expect(feed(reassembler, chunks), frames);
      });

      test('a 16 KiB frame needs the expected number of chunks', () {
        final n = BleChunker()
            .split(bytes(kBleMaxFrameBytes), attPayload: att)
            .length;
        expect(n, (kBleMaxFrameBytes / (att - 2)).ceil());
      });
    });
  }

  group('sequence numbers', () {
    test('wrap from 255 to 0 inside one frame', () {
      // 16 KiB at MTU 23 is 911 chunks: the counter wraps three times.
      final chunker = BleChunker();
      final chunks = chunker.split(bytes(kBleMaxFrameBytes), attPayload: 20);
      expect(chunks.length, greaterThan(768));
      for (final (i, c) in chunks.indexed) {
        expect(c[1], i % 256);
      }
      final out = feed(BleReassembler(), chunks);
      expect(out.single, bytes(kBleMaxFrameBytes));
    });

    test('run on across frames and wrap between them', () {
      final chunker = BleChunker();
      final reassembler = BleReassembler();
      // 300 one-chunk frames: seq 0..255, then 0..43.
      for (var i = 0; i < 300; i++) {
        final chunks = chunker.split(Uint8List.fromList([i & 0xff]),
            attPayload: 20);
        expect(chunks.single[1], i % 256);
        expect(feed(reassembler, chunks).single, [i & 0xff]);
      }
      expect(chunker.nextSeq, 300 % 256);
      expect(reassembler.expectedSeq, 300 % 256);
    });
  });

  group('violations close the stream', () {
    List<Uint8List> twoFrames() {
      final chunker = BleChunker();
      return [
        ...chunker.split(bytes(100, 1), attPayload: 20),
        ...chunker.split(bytes(100, 2), attPayload: 20),
      ];
    }

    test('a missing chunk is a sequence gap', () {
      final chunks = twoFrames()..removeAt(3);
      final r = BleReassembler();
      expect(() => feed(r, chunks), throwsA(isA<BleChunkException>()));
      expect(r.failure!.message, contains('Sequence gap'));
    });

    test('a missing LAST chunk is caught by the next frame', () {
      final chunks = twoFrames();
      final lastOfFirst = chunks.indexWhere((c) => c[0] & kBleFlagLast != 0);
      chunks.removeAt(lastOfFirst);
      expect(() => feed(BleReassembler(), chunks),
          throwsA(isA<BleChunkException>()));
    });

    test('a repeated chunk is a sequence gap', () {
      final chunks = twoFrames();
      chunks.insert(2, chunks[1]);
      expect(() => feed(BleReassembler(), chunks),
          throwsA(isA<BleChunkException>()));
    });

    test('swapped chunks are a sequence gap', () {
      final chunks = twoFrames();
      final a = chunks[1];
      chunks[1] = chunks[2];
      chunks[2] = a;
      expect(() => feed(BleReassembler(), chunks),
          throwsA(isA<BleChunkException>()));
    });

    test('a continuation without FIRST is rejected', () {
      final chunk = Uint8List.fromList([0, 0, 1, 2, 3]);
      expect(() => BleReassembler().add(chunk),
          throwsA(isA<BleChunkException>()));
    });

    test('FIRST inside a frame is rejected', () {
      final r = BleReassembler();
      expect(r.add(Uint8List.fromList([kBleFlagFirst, 0, 1])), isNull);
      expect(() => r.add(Uint8List.fromList([kBleFlagFirst, 1, 2])),
          throwsA(isA<BleChunkException>()));
    });

    test('a chunk shorter than its header is rejected', () {
      expect(() => BleReassembler().add(Uint8List.fromList([1])),
          throwsA(isA<BleChunkException>()));
    });

    test('a frame over the 16 KiB cap is rejected while it grows', () {
      // A hostile sender keeps a frame open past the cap.
      final r = BleReassembler();
      final body = Uint8List(510);
      var seq = 0;
      Object? error;
      try {
        r.add(Uint8List.fromList([kBleFlagFirst, seq++, ...body]));
        for (var i = 0; i < 40; i++) {
          r.add(Uint8List.fromList([0, seq++ & 0xff, ...body]));
        }
      } on BleChunkException catch (e) {
        error = e;
      }
      expect(error, isA<BleChunkException>());
      expect('$error', contains('Frame over'));
    });

    test('after a violation every chunk is refused', () {
      final r = BleReassembler();
      expect(() => r.add(Uint8List.fromList([kBleFlagFirst, 7, 1])),
          throwsA(isA<BleChunkException>()));
      // Even the chunk that would have been next.
      expect(() => r.add(Uint8List.fromList([3, 0, 1])),
          throwsA(isA<BleChunkException>()));
    });
  });

  group('chunker input checks', () {
    test('refuses frames over the cap', () {
      expect(() => BleChunker().split(bytes(kBleMaxFrameBytes + 1),
          attPayload: 512), throwsArgumentError);
    });

    test('refuses an ATT payload with no room for data', () {
      expect(() => BleChunker().split(bytes(10), attPayload: 2),
          throwsArgumentError);
    });

    test('the reassembler copies chunk data', () {
      final chunk = Uint8List.fromList([3, 0, 9, 9]);
      final frame = BleReassembler().add(chunk)!;
      chunk[2] = 0;
      expect(frame, [9, 9]);
    });
  });
}
