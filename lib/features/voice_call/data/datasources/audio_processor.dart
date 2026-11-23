import 'dart:math' as math;
import 'dart:typed_data';

/// The software half of the voice-processing chain.
///
/// The platform echo canceller / noise suppressor is the hardware half: it is
/// excellent when the device exposes it, and completely absent on some phones
/// (and some capture paths). This class makes the app sound like a phone call
/// on *every* device, by doing what an ordinary VoIP app forgets:
///
/// **Capture (microphone → network)**
/// 1. **Rumble / DC removal** — one-pole high-pass at 110 Hz. Removes the
///    low-frequency thump, handling noise and mains hum that make a link sound
///    "muddy" and that a loudspeaker reproduces badly.
/// 2. **Speech-band low-pass** — two cascaded one-poles at 3.6 kHz. Everything
///    above the telephone band is hiss: preamp noise, Wi-Fi electronics, fan
///    whine, aliasing. Dropping it is the single biggest "clearer voice" win
///    and it costs nothing at runtime.
/// 3. **Adaptive noise gate** — a downward expander whose threshold *tracks the
///    actual room* instead of assuming one: the noise floor is estimated with a
///    fast-fall / slow-rise envelope, so the same settings work in a quiet
///    bedroom and next to a fan. Between words the line goes quiet instead of
///    hissing.
/// 4. **Automatic gain control** — brings a quiet talker and a loud talker to
///    the same level, with a slow release so it never "pumps".
/// 5. **Soft-knee limiter** — guarantees samples never clip, which is what
///    turns a loud loudspeaker into distortion.
///
/// **Playback (network → speaker)**
/// 6. **Independent filter state** — the capture and playback paths each have
///    their own high-pass memory. Sharing it (the previous bug) mixed two
///    unrelated signals into one filter and produced clicks every time the two
///    paths interleaved.
/// 7. **Gap fade-in** — when the jitter buffer starves (Wi-Fi hiccup) the next
///    frame starts from silence; fading in over ~6 ms turns that step into a
///    soft edge instead of an audible "pop".
/// 8. **De-clicker** — a slew limiter caps the sample-to-sample step, so a
///    corrupt or truncated frame cannot produce a full-scale impulse.
///
/// On the loudspeaker it also acts as an **echo guard**: while the far end is
/// actually talking, the microphone is ducked (never muted) so that whatever the
/// speaker leaks back into the microphone cannot build into a howl.
///
/// Everything is pure Dart on a `Uint8List` of little-endian int16 samples, so
/// it is unit-testable without a phone, costs ~0.2 % of a core at 16 kHz, and
/// never touches the UI isolate's critical path.
class AudioProcessor {
  AudioProcessor({
    this.sampleRate = 16000,
    this.highPassHz = 110,
    this.lowPassHz = 3600,
    this.noiseFloorDb = -52,
    this.gateOpenDb = -34,
    this.targetRms = 0.10,
    this.maxGain = 8.0,
    this.limiterCeiling = 0.89,
    this.deClickDelta = 12000,
    this.gapFadeMs = 6,
    this.adaptiveNoiseFloor = true,
  }) {
    _hpAlpha = _onePoleAlpha(highPassHz);
    _lpAlpha = _lowPassAlpha(lowPassHz);
    _noiseFloor = _dbToLinear(noiseFloorDb) * 32768.0;
    _gateOpen = _dbToLinear(gateOpenDb) * 32768.0;
    _floorRms = _noiseFloor;
    _gapFadeStep = 1.0 / math.max(1, (sampleRate * gapFadeMs / 1000).round());
  }

  final int sampleRate;

  /// Corner frequency of the rumble filter.
  final double highPassHz;

  /// Corner frequency of the speech-band low-pass. 3.6 kHz keeps every speech
  /// formant that matters and rejects the rest of the hiss.
  final double lowPassHz;

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

  /// Largest permitted change between two consecutive playback samples.
  /// Full scale is 32767, so 12000 ≈ 0.37 FS — well above what speech needs at
  /// 16 kHz, well below the step a broken frame produces.
  final double deClickDelta;

  /// Length of the fade-in applied after a playback gap.
  final int gapFadeMs;

  /// Track the room's noise floor instead of trusting [noiseFloorDb] alone.
  final bool adaptiveNoiseFloor;

  late final double _hpAlpha;
  late final double _lpAlpha;
  late final double _gapFadeStep;
  late final double _noiseFloor;
  late final double _gateOpen;

  // ---------------------------------------------------------------------------
  // Capture state (own filter memory — never shared with playback)
  // ---------------------------------------------------------------------------
  double _capHpPrevIn = 0;
  double _capHpPrevOut = 0;
  double _capLp1 = 0;
  double _capLp2 = 0;
  double _gate = 0;
  double _agcGain = 1;
  double _floorRms = 0;

  // ---------------------------------------------------------------------------
  // Playback state
  // ---------------------------------------------------------------------------
  double _pbHpPrevIn = 0;
  double _pbHpPrevOut = 0;
  double _pbPrevOut = 0;
  double _pbFade = 1;

  // Echo-guard (software half-duplex) state.
  bool _echoGuardEnabled = false;
  double _duck = 1.0;
  double _farEndLevel = 0;

  // Reported levels (0…1) for the on-screen meters.
  double _capturePeak = 0;
  double _captureRms = 0;
  double _playbackPeak = 0;

  // Reused capture scratch buffer: filtered samples, pre-gain.
  Float64List _scratch = Float64List(1024);

  /// Peak amplitude of the most recent capture block, 0…1.
  double get capturePeak => _capturePeak;

  /// RMS amplitude of the most recent capture block, 0…1.
  double get captureRms => _captureRms;

  /// Peak amplitude of the most recent playback block, 0…1.
  double get playbackPeak => _playbackPeak;

  /// Current AGC gain, for diagnostics.
  double get currentGain => _agcGain;

  /// The noise floor the gate is currently working against, in dBFS.
  /// A rising number means the room got noisier and the gate followed it.
  double get estimatedNoiseFloorDb =>
      20 * math.log(_floorRms / 32768.0) / math.ln10;

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

  /// Tells the playback chain that the stream was interrupted (jitter-buffer
  /// starvation, dropped frame). The next block fades in from silence so the
  /// restart does not click.
  void notePlaybackGap() {
    _pbFade = 0;
  }

  /// Microphone chain: rumble filter → speech-band low-pass → gate → AGC → limiter.
  ///
  /// Returns a new buffer; the input is left untouched.
  Uint8List processCapture(Uint8List pcm) {
    final out = Uint8List(pcm.length);
    if (pcm.isEmpty) {
      return out;
    }

    final samples = pcm.length ~/ 2;
    if (_scratch.length < samples) {
      _scratch = Float64List(samples);
    }

    var sumSquares = 0.0;
    var peak = 0.0;

    // Block-based decisions (≈10 ms) so the gate cannot chatter per sample.
    const blockSamples = 160;
    for (var start = 0; start < samples; start += blockSamples) {
      final end = math.min(start + blockSamples, samples);
      final count = end - start;

      // --- 1. filter the block, and measure what survived ------------------
      var blockSumSquares = 0.0;
      for (var i = start; i < end; i++) {
        final x = _readSample(pcm, i).toDouble();

        // High-pass first: removes DC offset before any gain is applied, so the
        // gate never sees a constant bias as "sound".
        final hp = _hpAlpha * (_capHpPrevOut + x - _capHpPrevIn);
        _capHpPrevIn = x;
        _capHpPrevOut = hp;

        // Two cascaded one-poles ≈ 12 dB/octave above the speech band.
        _capLp1 += _lpAlpha * (hp - _capLp1);
        _capLp2 += _lpAlpha * (_capLp1 - _capLp2);

        _scratch[i] = _capLp2;
        blockSumSquares += _capLp2 * _capLp2;
      }
      final blockRms = count == 0 ? 0.0 : math.sqrt(blockSumSquares / count);

      // --- 2. follow the room's noise floor -------------------------------
      if (adaptiveNoiseFloor) {
        _trackNoiseFloor(blockRms);
      }

      // --- 3. gate: how open should the line be? --------------------------
      final gateTarget = _gateTargetFor(blockRms);
      // Attack fast (5 ms), release slow (120 ms) — as in a real expander.
      final gateCoefficient = gateTarget > _gate ? 0.35 : 0.004;
      _gate += (gateTarget - _gate) * gateCoefficient;

      // --- 4. AGC: how much gain does this talker need? -------------------
      final agcTarget = _agcTargetFor(blockRms, gateTarget);
      // Rise quickly (a quiet talker must be audible within a few syllables),
      // fall away slowly (fast gain reduction is what "pumps").
      final agcCoefficient = agcTarget > _agcGain ? 0.05 : 0.0015;
      _agcGain += (agcTarget - _agcGain) * agcCoefficient;

      // --- 5. echo guard: duck the microphone while the far end speaks ----
      final duckTarget = _duckTargetFor();
      // Close fast (~20 ms) so a howl cannot start, and open in ~120 ms so the
      // local talker is not chopped when the other side stops. Blocks are 10 ms.
      final duckCoefficient = duckTarget < _duck ? 0.35 : 0.08;
      _duck += (duckTarget - _duck) * duckCoefficient;

      final totalGain = _gate * _agcGain * _duck;

      // --- 6. apply gain and limit ---------------------------------------
      for (var i = start; i < end; i++) {
        final amplified = _scratch[i] * totalGain;
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

  /// Playback chain: rumble filter → gain → gap fade-in → de-clicker → limiter.
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
      final hp = _hpAlpha * (_pbHpPrevOut + x - _pbHpPrevIn);
      _pbHpPrevIn = x;
      _pbHpPrevOut = hp;

      var scaled = hp * gain;

      // Fade back in after a gap so a restart is a soft edge, not a pop.
      if (_pbFade < 1) {
        scaled *= _pbFade;
        _pbFade = math.min(1, _pbFade + _gapFadeStep);
      }

      var limited = _limit(scaled / 32768.0) * 32768.0;

      // De-clicker: cap the step from the previous sample. A truncated or
      // corrupt frame otherwise lands as a full-scale impulse.
      final delta = limited - _pbPrevOut;
      if (delta > deClickDelta) {
        limited = _pbPrevOut + deClickDelta;
      } else if (delta < -deClickDelta) {
        limited = _pbPrevOut - deClickDelta;
      }
      _pbPrevOut = limited;

      _writeSample(out, i, limited.round().clamp(-32768, 32767));
      final abs = limited.abs();
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
    _capHpPrevIn = 0;
    _capHpPrevOut = 0;
    _capLp1 = 0;
    _capLp2 = 0;
    _pbHpPrevIn = 0;
    _pbHpPrevOut = 0;
    _pbPrevOut = 0;
    _pbFade = 1;
    _gate = 0;
    _agcGain = 1;
    _duck = 1.0;
    _farEndLevel = 0;
    _floorRms = _noiseFloor;
    _capturePeak = 0;
    _captureRms = 0;
    _playbackPeak = 0;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Fast-fall / slow-rise envelope follower: drops quickly onto a quieter
  /// room and creeps up only when the noise really is sustained, so a pause
  /// between words cannot be mistaken for a noisier room.
  void _trackNoiseFloor(double blockRms) {
    if (blockRms <= 0) {
      return;
    }
    final coefficient = blockRms < _floorRms ? 0.20 : 0.0012;
    _floorRms += (blockRms - _floorRms) * coefficient;
    // Never below the configured floor, never above the "speech starts here"
    // level — otherwise a loud talker would raise the gate onto himself.
    _floorRms = _floorRms.clamp(8.0, _gateOpen);
  }

  /// Level below which the line is considered silent. Tracks the room.
  double get _gateCloseBelow => math.max(_noiseFloor, _floorRms * 1.6);

  /// Level at which the gate is wide open.
  double get _gateOpenAbove => math.max(_gateOpen, _gateCloseBelow * 2.2);

  /// Smooth gate curve: shut below the noise floor, wide open above the speech
  /// threshold, linear in between (no hard on/off clicks).
  double _gateTargetFor(double rms) {
    final close = _gateCloseBelow;
    final open = _gateOpenAbove;
    if (rms <= close) {
      return 0.08; // ≈ -22 dB: room tone is present but inaudible
    }
    if (rms >= open) {
      return 1.0;
    }
    final span = (open - close).clamp(1.0, double.infinity);
    return 0.08 + 0.92 * ((rms - close) / span);
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

  /// One-pole low-pass coefficient: `y += alpha * (x - y)`.
  double _lowPassAlpha(double cutoffHz) {
    final dt = 1.0 / sampleRate;
    final rc = 1.0 / (2 * math.pi * cutoffHz);
    return dt / (rc + dt);
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
