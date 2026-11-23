import 'dart:typed_data';

import 'package:esp32_voip/core/utils/constants.dart';
import 'package:esp32_voip/features/voice_call/data/datasources/pcm_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PcmChunker', () {
    test('emits exact 40 ms frames regardless of incoming block size', () {
      final chunker = PcmChunker();
      final frames = <Uint8List>[];

      // 512-byte native blocks are not a multiple of 1280.
      for (var i = 0; i < 20; i++) {
        frames.addAll(chunker.add(Uint8List(512)));
      }

      expect(frames, isNotEmpty);
      for (final frame in frames) {
        expect(frame.length, AudioConstants.bytesPerFrame);
      }
      final emitted = frames.length * AudioConstants.bytesPerFrame;
      expect(emitted + chunker.pendingBytes, 20 * 512);
    });

    test('carries a partial frame over to the next call', () {
      final chunker = PcmChunker();
      final first = chunker.add(Uint8List(1000));
      expect(first, isEmpty);
      expect(chunker.pendingBytes, 1000);

      final second = chunker.add(Uint8List(320));
      expect(second.length, 1);
      expect(second.single.length, AudioConstants.bytesPerFrame);
      expect(chunker.pendingBytes, 40);
    });

    test('caps the backlog so latency cannot grow without bound', () {
      final chunker = PcmChunker();
      // Push ~1 second of audio in one burst.
      chunker.add(Uint8List(AudioConstants.sampleRate * 2));

      expect(chunker.droppedBytes, greaterThan(0));
      expect(chunker.pendingBytes, lessThan(AudioConstants.maxOutboundBacklogBytes));
    });

    test('reset clears the carry-over buffer', () {
      final chunker = PcmChunker()..add(Uint8List(700));
      chunker.reset();
      expect(chunker.pendingBytes, 0);
      expect(chunker.droppedBytes, 0);
    });
  });
}
