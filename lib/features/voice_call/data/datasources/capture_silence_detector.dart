import 'dart:typed_data';

/// Watches the microphone for *digital* silence and decides when the current
/// capture configuration is almost certainly broken.
///
/// This exists because of the single most common cause of "the call connects but
/// nobody hears anybody": Android hands back all-zero buffers when a capture
/// source is not supported by the device — typically `VOICE_COMMUNICATION` with
/// hardware echo cancellation on phones whose voice path needs the telephony
/// stack. Nothing throws, the stream stays alive, and the app cheerfully sends
/// 40 ms of zeros 25 times a second.
///
/// Rather than guessing per device, the app measures: after a short grace period,
/// if the peak sample stays at (near) zero for a whole second, the capture
/// configuration is escalated to the next fallback profile.
class CaptureSilenceDetector {
  CaptureSilenceDetector({
    this.silentFramesToEscalate = 25,
    this.silenceThreshold = 8,
    this.graceFrames = 12,
  });

  /// 25 frames × 40 ms = one second of nothing at all.
  final int silentFramesToEscalate;

  /// Peak amplitude (0…32767) at or below which a frame counts as silence.
  /// 8 LSB is inaudible on any phone; real room tone is far above it.
  final int silenceThreshold;

  /// A device needs a moment after `startRecorder` before buffers arrive.
  final int graceFrames;

  int _frameIndex = 0;
  int _consecutiveSilent = 0;

  /// True once this detector has fired and not yet been reset.
  bool get hasFired => _consecutiveSilent >= silentFramesToEscalate;

  int get silentFrameCount => _consecutiveSilent;

  /// Feed one captured block. Returns `true` exactly once, on the frame where
  /// the run of silence becomes long enough to escalate.
  bool add(Uint8List pcm) {
    _frameIndex++;
    if (_frameIndex <= graceFrames) {
      return false;
    }
    if (pcm.length < 2) {
      return false;
    }

    var peak = 0;
    final samples = pcm.length ~/ 2;
    for (var i = 0; i < samples; i++) {
      final lo = pcm[i * 2];
      final hi = pcm[i * 2 + 1];
      final value = (hi << 8) | lo;
      final abs = value >= 0x8000 ? 0x10000 - value : value;
      if (abs > peak) {
        peak = abs;
        if (peak > silenceThreshold) {
          _consecutiveSilent = 0;
          return false;
        }
      }
    }

    _consecutiveSilent++;
    if (_consecutiveSilent == silentFramesToEscalate) {
      return true;
    }
    return false;
  }

  void reset() {
    _frameIndex = 0;
    _consecutiveSilent = 0;
  }
}
