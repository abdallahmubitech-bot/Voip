import 'dart:typed_data';

import 'package:esp32_voip/features/voice_call/data/datasources/capture_silence_detector.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List frame(int amplitude, {int samples = 640}) {
  final out = Uint8List(samples * 2);
  for (var i = 0; i < samples; i++) {
    final v = amplitude * ((i % 2 == 0) ? 1 : -1);
    out[i * 2] = v & 0xFF;
    out[i * 2 + 1] = (v >> 8) & 0xFF;
  }
  return out;
}

void main() {
  group('CaptureSilenceDetector', () {
    test('does not fire during the grace period', () {
      final detector = CaptureSilenceDetector(graceFrames: 12);

      for (var i = 0; i < 12; i++) {
        expect(detector.add(frame(0)), isFalse);
      }
      expect(detector.hasFired, isFalse);
    });

    test('fires once after a full second of digital silence', () {
      final detector =
          CaptureSilenceDetector(silentFramesToEscalate: 25, graceFrames: 0);

      var fired = 0;
      for (var i = 0; i < 40; i++) {
        if (detector.add(frame(0))) {
          fired++;
        }
      }

      expect(fired, 1, reason: 'escalation must happen exactly once per run');
      expect(detector.hasFired, isTrue);
    });

    test('never fires while real audio is present', () {
      final detector = CaptureSilenceDetector(graceFrames: 0);

      for (var i = 0; i < 200; i++) {
        expect(detector.add(frame(300)), isFalse);
      }
      expect(detector.hasFired, isFalse);
    });

    test('a single loud block cancels the silent run (bg noise is enough)', () {
      final detector =
          CaptureSilenceDetector(silentFramesToEscalate: 25, graceFrames: 0);

      for (var i = 0; i < 20; i++) {
        detector.add(frame(0));
      }
      detector.add(frame(50)); // someone speaks / room tone rises
      for (var i = 0; i < 20; i++) {
        expect(detector.add(frame(0)), isFalse);
      }

      expect(detector.hasFired, isFalse);
    });

    test('tiny but non-zero noise floor does not trigger the fallback', () {
      // 8 LSB is the documented threshold: real microphones always exceed it.
      final detector =
          CaptureSilenceDetector(silentFramesToEscalate: 5, graceFrames: 0);

      for (var i = 0; i < 50; i++) {
        expect(detector.add(frame(9)), isFalse);
      }
    });

    test('reset clears the run', () {
      final detector =
          CaptureSilenceDetector(silentFramesToEscalate: 3, graceFrames: 0);
      detector.add(frame(0));
      detector.add(frame(0));
      detector.add(frame(0));

      detector.reset();

      expect(detector.hasFired, isFalse);
      expect(detector.add(frame(0)), isFalse);
    });

    test('tolerates empty and one-byte buffers', () {
      final detector = CaptureSilenceDetector(graceFrames: 0);

      expect(detector.add(Uint8List(0)), isFalse);
      expect(detector.add(Uint8List(1)), isFalse);
    });
  });
}
