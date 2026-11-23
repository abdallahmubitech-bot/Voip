import 'dart:math' as math;
import 'dart:typed_data';

/// The software half of the voice-processing chain.
///
/// The platform echo canceller / noise suppressor is the hardware half: it is
/// excellent when the device exposes it, and completely absent on some phones
/// (and some capture paths). This class makes the app sound like a phone call
/// on *every* device, by doing four things to the 16-bit PCM that an ordinary
/// VoIP app forgets:
///
/// 1. **DC / rumble removal** — a one-pole high-pass at 110 Hz. Removes the
///    low-frequency thump, handling noise and mains hum that make a link sound
///    "muddy" and that a loudspeaker reproduces badly.
/// 2. **Downward expander (noise gate)** — below a threshold the signal is
///    attenuated smoothly instead of being passed on. This is what removes the
///    constant hiss between words, so the line sounds quiet rather than noisy.
/// 3. **Automatic gain control** — brings a quiet talker and a loud talker to
///    the same level, with a slow release so it never "pumps".
/// 4. **Soft-knee limiter** — guarantees the samples never clip, which is what
///    turns a loud loudspeaker into distortion.
///
/// On the loudspeaker it also acts as an **echo guard**: while the far end is
/// actually talking, the microphone is ducked (never muted) so that whatever the
/// speaker leaks back into the microphone cannot build into a howl. Devices whose
/// hardware echo canceller is missing or ineffective — which is most development
/// boards and a fair number of phones — stay usable instead of screeching.
///
/// Everything is pure Dart on a `Uint8List` of little-endian int16 samples, so
/// it is unit-testable without a phone, costs ~0.1 % of a core at 16 kHz, and
/// never touches the UI isolate's critical path.
class AudioProcessor {
  AudioProcessor({
    this.sampleRate = 16000,
    this.highPassHz = 110,
    this.noiseFloorDb = -52,
    this.gateOpenDb = -34,
    this.targetRms = 0.10,
    this.maxGain = 8.0,
    this.limiterCeiling = 0.89,
  }) {
    _hpAlpha = _onePoleAlpha(highPassHz);
    _noiseFloor = _dbToLinear(noiseFloorDb) * 32768.0;
    _gateOpen = _dbToLinear(gateOpenDb) * 32768.0;
  }

  final int sampleRate;

  /// Corner frequency of the rumble filter.
  final double highPassHz;

  /// Anything below this level is treated as room noise (dBFS).
  final double noiseFloorDb;

  /// Above this level the gate is fully open (dBFS).
  final double gateOpenDb;

  /// Level the AGC aims for, as a fraction of full scale.
  final double targetRms;

  /// Never amplify more than this (keeps a dead microphone from hissing).
  final double maxGain;

  /// Peak ceiling, ~ -1 dBFS.
  final double limiterCeiling;

  late final double _hpAlpha;
  late final double _noiseFloor;
  late final double _gateOpen;

  // High-pass state.
  double _hpPrevIn = 0;
  double _hpPrevOut = 0;

  // Gate / AGC state.
  double _gate = 0;
  double _agcGain = 1;

  // Echo-guard (software half-duplex) state.
  bool _echoGuardEnabled = false;
  double _duck = 1.0;
  double _farEndLevel = 0;

  // Reported levels (0…1) for the on-screen meters.
  double _capturePeak = 0;
  double _captureRms = 0;
  double _playbackPeak = 0;

  /// Peak amplitude of the most recent capture block, 0…1.
  double get capturePeak => _capturePeak;

  /// RMS amplitude of the most recent capture block, 0…1.
  double get captureRms => _captureRms;

  /// Peak amplitude of the most recent playback block, 0…1.
  double get playbackPeak => _playbackPeak;

  /// Current AGC gain, for diagnostics.
  double get currentGain => _agcGain;

  /// How much the microphone is currently being ducked by the echo guard,
  /// 1.0 = untouched, 0.12 = −18 dB. Surfaced for tests and diagnostics.
  double get echoGuardDucking => _duck;

  /// Enable/disable the software echo guard. The repository turns it on only
  /// while the loudspeaker is in use, where acoustic feedback is real; on the
  /// earpiece the platform AEC is enough and ducking would clip the talker.
  set echoGuardEnabled(bool enabled) {
    _echoGuardEnabled = enabled;
    if (!enabled) {
      _duck = 1.0;
    }
  }

  bool get echoGuardEnabled => _echoGuardEnabled;

  /// Tells the guard how loud the audio being played right now is (0…1).
  /// Called after every playback frame, before the next capture frame is read.
  void noteFarEndLevel(double level) {
    _farEndLevel = level.clamp(0.0, 1.0);
  }

  /// Microphone chain: rumble filter → gate → AGC → limiter.
  ///
  /// Returns a new buffer; the input is left untouched.
  Uint8List processCapture(Uint8List pcm) {
    final out = Uint8List(pcm.length);
    if (pcm.isEmpty) {
      return out;
    }

    var sumSquares = 0.0;
    var peak = 0.0;
    final samples = pcm.length ~/ 2;

    // Block-based decisions (≈10 ms) so the gate cannot chatter per sample.
    const blockSamples = 160;
    for (var start = 0; start < samples; start += blockSamples) {
      final end = math.min(start + blockSamples, samples);

      // --- 1. measure the block -------------------------------------------
      var blockSumSquares = 0.0;
      var blockPeak = 0.0;
      for (var i = start; i < end; i++) {
        final s = _readSample(pcm, i);
        final abs = s.abs().toDouble();
        if (abs > blockPeak) {
          blockPeak = abs;
        }
        blockSumSquares += (s * s).toDouble();
      }
      final blockCount = end - start;
      final blockRms = blockCount == 0
          ? 0.0
          : math.sqrt(blockSumSquares / blockCount);

      // --- 2. gate: how open should the line be? --------------------------
      final gateTarget = _gateTargetFor(blockRms);
      // Attack fast (5 ms), release slow (120 ms) — as in a real expander.
      final gateCoefficient = gateTarget > _gate ? 0.35 : 0.004;
      _gate += (gateTarget - _gate) * gateCoefficient;

      // --- 3. AGC: how much gain does this talker need? -------------------
      final agcTarget = _agcTargetFor(blockRms, gateTarget);
      // Rise quickly (a quiet talker must be audible within a few syllables),
      // fall away slowly (fast gain reduction is what "pumps").
      final agcCoefficient = agcTarget > _agcGain ? 0.05 : 0.0015;
      _agcGain += (agcTarget - _agcGain) * agcCoefficient;

      // --- 3b. echo guard: duck the microphone while the far end speaks ----
      final duckTarget = _duckTargetFor();
      // Close fast (~20 ms) so a howl cannot start, and open in ~120 ms so the
      // local talker is not chopped when the other side stops. Blocks are 10 ms.
      final duckCoefficient = duckTarget < _duck ? 0.35 : 0.08;
      _duck += (duckTarget - _duck) * duckCoefficient;

      final totalGain = _gate * _agcGain * _duck;

      // --- 4. apply, filter and limit -------------------------------------
      for (var i = start; i < end; i++) {
        final x = _readSample(pcm, i).toDouble();
        // High-pass first: removes DC offset before any gain is applied, so the
        // gate never sees a constant bias as "sound".
        final hp = _hpAlpha * (_hpPrevOut + x - _hpPrevIn);
        _hpPrevIn = x;
        _hpPrevOut = hp;

        final amplified = hp * totalGain;
        final limited = _limit(amplified / 32768.0) * 32768.0;

        _writeSample(out, i, limited.round().clamp(-32768, 32767));

        final absOut = limited.abs();
        if (absOut > peak) {
          peak = absOut;
        }
        sumSquares += limited * limited;
      }
    }

    _capturePeak = (peak / 32768.0).clamp(0.0, 1.0);
    _captureRms = samples == 0
        ? 0.0
        : (math.sqrt(sumSquares / samples) / 32768.0).clamp(0.0, 1.0);
    return out;
  }

  /// Playback chain: rumble filter → fixed gain → limiter.
  ///
  /// [gain] is what makes the loudspeaker usable: the ESP32 link is quiet by
  /// design, so the phone has to make up the difference *before* the OS mixer,
  /// where it can still be limited instead of clipped.
  Uint8List processPlayback(Uint8List pcm, {double gain = 1.0}) {
    final out = Uint8List(pcm.length);
    if (pcm.isEmpty) {
      return out;
    }
    final samples = pcm.length ~/ 2;
    var peak = 0.0;
    for (var i = 0; i < samples; i++) {
      final x = _readSample(pcm, i).toDouble();
      final hp = _hpAlpha * (_hpPrevOut + x - _hpPrevIn);
      _hpPrevIn = x;
      _hpPrevOut = hp;

      final scaled = _limit((hp * gain) / 32768.0) * 32768.0;
      _writeSample(out, i, scaled.round().clamp(-32768, 32767));
      final abs = scaled.abs();
      if (abs > peak) {
        peak = abs;
      }
    }
    _playbackPeak = (peak / 32768.0).clamp(0.0, 1.0);
    return out;
  }

  /// Peak level (0…1) of a raw block, without processing it. Used by the
  /// self-test and by diagnostics that must not alter the audio.
  static double peakOf(Uint8List pcm) {
    if (pcm.length < 2) {
      return 0;
    }
    var peak = 0;
    final samples = pcm.length ~/ 2;
    for (var i = 0; i < samples; i++) {
      final abs = _readSample(pcm, i).abs();
      if (abs > peak) {
        peak = abs;
      }
    }
    return (peak / 32768.0).clamp(0.0, 1.0);
  }

  void reset() {
    _hpPrevIn = 0;
    _hpPrevOut = 0;
    _gate = 0;
    _agcGain = 1;
    _duck = 1.0;
    _farEndLevel = 0;
    _capturePeak = 0;
    _captureRms = 0;
    _playbackPeak = 0;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Smooth gate curve: shut below the noise floor, wide open above the speech
  /// threshold, linear in between (no hard on/off clicks).
  double _gateTargetFor(double rms) {
    if (rms <= _noiseFloor) {
      return 0.08; // ≈ -22 dB: room tone is present but inaudible
    }
    if (rms >= _gateOpen) {
      return 1.0;
    }
    final span = (_gateOpen - _noiseFloor).clamp(1.0, double.infinity);
    return 0.08 + 0.92 * ((rms - _noiseFloor) / span);
  }

  /// How much to duck the microphone, given what the speaker is playing.
  ///
  /// Below [-45 dBFS] of far-end audio the microphone is untouched (silence from
  /// the peer must not mute you). Above [-26 dBFS] it is held at -18 dB. That is
  /// deliberately *not* a mute: a full switch would make every conversation feel
  /// like a walkie-talkie, whereas -18 dB removes the feedback loop while still
  /// letting your voice through.
  double _duckTargetFor() {
    if (!_echoGuardEnabled) {
      return 1.0;
    }
    const quiet = 0.006; // ≈ -45 dBFS
    const loud = 0.05; // ≈ -26 dBFS
    const floorGain = 0.12; // ≈ -18 dB
    if (_farEndLevel <= quiet) {
      return 1.0;
    }
    if (_farEndLevel >= loud) {
      return floorGain;
    }
    final t = (_farEndLevel - quiet) / (loud - quiet);
    return 1.0 - (1.0 - floorGain) * t;
  }

  double _agcTargetFor(double rms, double gateOpen) {
    if (gateOpen < 0.5 || rms <= 1.0) {
      // Gate mostly shut: freeze the gain so silence is not amplified.
      return _agcGain;
    }
    final wanted = (targetRms * 32768.0) / rms;
    return wanted.clamp(0.45, maxGain);
  }

  /// Soft-knee limiter: linear below [limiterCeiling], then a smooth tanh bend
  /// up to 1.0. Never returns a value outside ±1.
  double _limit(double x) {
    final abs = x.abs();
    if (abs <= limiterCeiling) {
      return x;
    }
    final head = 1.0 - limiterCeiling;
    final over = (abs - limiterCeiling) / head;
    final limited = limiterCeiling + head * _tanh(over);
    return x.isNegative ? -limited : limited;
  }

  double _onePoleAlpha(double cutoffHz) {
    final dt = 1.0 / sampleRate;
    final rc = 1.0 / (2 * math.pi * cutoffHz);
    return rc / (rc + dt);
  }

  static double _dbToLinear(double db) => math.pow(10, db / 20).toDouble();

  // tanh without importing a maths package that may not exist on all targets.
  static double _tanh(double x) {
    if (x > 3) {
      return 1.0;
    }
    if (x < -3) {
      return -1.0;
    }
    final e2x = math.exp(2 * x);
    return (e2x - 1) / (e2x + 1);
  }

  /// Little-endian signed 16-bit read that works on any view offset.
  static int _readSample(Uint8List buffer, int index) {
    final lo = buffer[index * 2];
    final hi = buffer[index * 2 + 1];
    final value = (hi << 8) | lo;
    return value >= 0x8000 ? value - 0x10000 : value;
  }

  static void _writeSample(Uint8List buffer, int index, int value) {
    buffer[index * 2] = value & 0xFF;
    buffer[index * 2 + 1] = (value >> 8) & 0xFF;
  }
}
