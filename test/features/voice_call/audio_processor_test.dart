import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esp32_voip/features/voice_call/data/datasources/audio_processor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds little-endian int16 PCM from a sample generator.
Uint8List pcmFrom(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i].clamp(-32768, 32767);
    out[i * 2] = v & 0xFF;
    out[i * 2 + 1] = (v >> 8) & 0xFF;
  }
  return out;
}

List<int> samplesOf(Uint8List pcm) {
  final out = <int>[];
  for (var i = 0; i < pcm.length ~/ 2; i++) {
    final lo = pcm[i * 2];
    final hi = pcm[i * 2 + 1];
    final v = (hi << 8) | lo;
    out.add(v >= 0x8000 ? v - 0x10000 : v);
  }
  return out;
}

/// A 300 Hz tone (well inside the speech band).
List<int> tone({required int count, double amplitude = 0.3, double hz = 300}) {
  return List<int>.generate(count, (i) {
    final t = i / 16000.0;
    return (math.sin(2 * math.pi * hz * t) * amplitude * 32767).round();
  });
}

void main() {
  group('AudioProcessor — capture chain', () {
    test('output is bit-for-bit a new buffer (input untouched)', () {
      final processor = AudioProcessor();
      final input = pcmFrom(tone(count: 320));
      final copy = Uint8List.fromList(input);

      final out = processor.processCapture(input);

      expect(out.length, input.length);
      expect(input, copy, reason: 'the source buffer must not be mutated');
    });

    test('removes a constant DC offset', () {
      final processor = AudioProcessor();
      // 2000 LSB of pure DC, no speech at all.
      final input = pcmFrom(List<int>.filled(1600, 2000));

      final out = samplesOf(processor.processCapture(input));

      // The high-pass settles towards zero; the tail must be near silent.
      final tail = out.sublist(out.length - 400);
      final peakTail =
          tail.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
      expect(peakTail, lessThan(200),
          reason: 'DC must be filtered out, not amplified');
    });

    test('attenuates room noise that is below the speech threshold', () {
      final processor = AudioProcessor();
      // ~ -60 dBFS hiss: below any speaking voice.
      final input = pcmFrom(List<int>.generate(4000, (i) => (i % 2 == 0) ? 30 : -30));

      final out = samplesOf(processor.processCapture(input));
      final peakOut = out.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

      expect(peakOut, lessThan(30),
          reason: 'the gate must not pass steady low-level noise through at unity');
    });

    test('lifts a quiet talker with AGC and never clips', () {
      final processor = AudioProcessor();
      final quiet = pcmFrom(tone(count: 8000, amplitude: 0.02));

      final out = samplesOf(processor.processCapture(quiet));

      final peak = out.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(0.02 * 32767),
          reason: 'a quiet signal should be amplified');
      expect(peak, lessThanOrEqualTo(32767));
    });

    test('a loud talker is limited, not clipped', () {
      final processor = AudioProcessor();
      final loud = pcmFrom(tone(count: 4000, amplitude: 0.99));

      final out = samplesOf(processor.processCapture(loud));

      final peak = out.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, lessThanOrEqualTo(32767));
      // Soft knee: samples should stay under full scale rather than flat-top.
      final atFullScale = out.where((s) => s.abs() >= 32767).length;
      expect(atFullScale, lessThan(out.length ~/ 10),
          reason: 'hard clipping is what makes a loudspeaker sound harsh');
    });

    test('reports a usable level for the on-screen meter', () {
      final processor = AudioProcessor();
      processor.processCapture(pcmFrom(tone(count: 1600, amplitude: 0.5)));

      expect(processor.capturePeak, greaterThan(0.05));
      expect(processor.capturePeak, lessThanOrEqualTo(1.0));
      expect(processor.captureRms, greaterThan(0));
    });

    test('digital silence stays silent (AGC must not amplify nothing)', () {
      final processor = AudioProcessor();
      final out = samplesOf(processor.processCapture(pcmFrom(List<int>.filled(3200, 0))));

      expect(out.every((s) => s == 0), isTrue);
      expect(processor.capturePeak, 0);
    });

    test('reset clears the filter and gain state', () {
      final processor = AudioProcessor();
      processor.processCapture(pcmFrom(tone(count: 1600, amplitude: 0.9)));
      expect(processor.currentGain, isNot(1.0));

      processor.reset();

      expect(processor.currentGain, 1.0);
      expect(processor.capturePeak, 0);
    });
  });

  group('AudioProcessor — playback chain', () {
    test('unity gain leaves a speech-level signal essentially unchanged', () {
      final processor = AudioProcessor();
      final input = pcmFrom(tone(count: 640, amplitude: 0.3));

      final out = samplesOf(processor.processPlayback(input, gain: 1.0));

      expect(out.length, 640);
      final peak = out.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(0)) ;
      expect(peak, lessThanOrEqualTo(32767));
    });

    test('speaker gain makes the loudspeaker louder without clipping', () {
      final quietProcessor = AudioProcessor();
      final quiet = pcmFrom(tone(count: 640, amplitude: 0.2));
      final atUnity = samplesOf(quietProcessor.processPlayback(quiet, gain: 1.0));
      final peakUnity =
          atUnity.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

      final loudProcessor = AudioProcessor();
      final atSpeaker =
          samplesOf(loudProcessor.processPlayback(quiet, gain: 2.2));
      final peakSpeaker =
          atSpeaker.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

      expect(peakSpeaker, greaterThan(peakUnity * 1.5));
      expect(peakSpeaker, lessThanOrEqualTo(32767),
          reason: 'the limiter must absorb the boost');
    });

    test('reports the peer level for the meter', () {
      final processor = AudioProcessor();
      processor.processPlayback(pcmFrom(tone(count: 320, amplitude: 0.4)));

      expect(processor.playbackPeak, greaterThan(0.05));
    });
  });

  group('AudioProcessor — echo guard (loudspeaker)', () {
    test('does nothing while the guard is disabled', () {
      final processor = AudioProcessor();
      final quiet = pcmFrom(tone(count: 1600, amplitude: 0.2));

      processor.noteFarEndLevel(0.9); // far end screaming
      final out = samplesOf(processor.processCapture(quiet));

      final peak = out.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(0.05 * 32767),
          reason: 'on the earpiece the talker must not be ducked');
      expect(processor.echoGuardDucking, 1.0);
    });

    test('ducks the microphone when the far end is loud', () {
      final processor = AudioProcessor()..echoGuardEnabled = true;
      final speech = pcmFrom(tone(count: 8000, amplitude: 0.25));

      // Speaker is playing the peer's voice at a level that would feed back.
      processor.noteFarEndLevel(0.6);
      final ducked = samplesOf(processor.processCapture(speech));
      final duckedPeak = ducked.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

      final reference = AudioProcessor();
      final plain = samplesOf(reference.processCapture(speech));
      final plainPeak = plain.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

      expect(processor.echoGuardDucking, lessThan(0.3),
          reason: 'the guard should approach -18 dB');
      expect(duckedPeak, lessThan(plainPeak * 0.5),
          reason: 'a feedback loop needs a large attenuation, not a mute');
      expect(duckedPeak, greaterThan(0),
          reason: 'the talker must still be audible — this is not a switch');
    });

    test('opens up again as soon as the far end stops', () {
      final processor = AudioProcessor()..echoGuardEnabled = true;
      final speech = pcmFrom(tone(count: 6400, amplitude: 0.25));

      processor.noteFarEndLevel(0.6);
      processor.processCapture(speech);
      expect(processor.echoGuardDucking, lessThan(0.5));

      // Peer went quiet: the guard must release quickly (≈120 ms).
      processor.noteFarEndLevel(0.0);
      for (var i = 0; i < 10; i++) {
        processor.processCapture(pcmFrom(tone(count: 1600, amplitude: 0.25)));
      }

      expect(processor.echoGuardDucking, greaterThan(0.9));
    });

    test('disabling the guard restores the microphone immediately', () {
      final processor = AudioProcessor()..echoGuardEnabled = true;
      processor.noteFarEndLevel(0.9);
      processor.processCapture(pcmFrom(tone(count: 1600, amplitude: 0.25)));
      expect(processor.echoGuardDucking, lessThan(1.0));

      processor.echoGuardEnabled = false;

      expect(processor.echoGuardDucking, 1.0);
    });

    test('quiet far-end audio never ducks the microphone', () {
      final processor = AudioProcessor()..echoGuardEnabled = true;

      processor.noteFarEndLevel(0.004); // below -45 dBFS
      processor.processCapture(pcmFrom(tone(count: 1600, amplitude: 0.25)));

      expect(processor.echoGuardDucking, greaterThan(0.99));
    });
  });

  group('AudioProcessor — wire safety', () {
    test('a frame whose length is odd keeps producing whole samples', () {
      final processor = AudioProcessor();
      // 1281-byte frames can happen if a firmware adds a byte; must not throw.
      final odd = Uint8List(1281)..fillRange(0, 1281, 12);

      expect(() => processor.processCapture(odd), returnsNormally);
      expect(processor.processPlayback(odd).length, 1281);
    });

    test('empty input is handled', () {
      final processor = AudioProcessor();
      expect(processor.processCapture(Uint8List(0)).isEmpty, isTrue);
      expect(processor.processPlayback(Uint8List(0)).isEmpty, isTrue);
      expect(AudioProcessor.peakOf(Uint8List(0)), 0);
    });
  });
}
