import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../../../core/utils/constants.dart';

/// Smooths out Wi-Fi jitter before handing PCM to the speaker.
///
/// Inbound frames arrive in bursts; the loudspeaker needs one frame every 40 ms.
/// Playback starts only once [prefill] frames are queued (≈120 ms of buffer) and
/// re-arms whenever the queue underruns.
class PlaybackJitterBuffer {
  PlaybackJitterBuffer({
    required this.onFrame,
    this.onInterruption,
    this.frameDuration = const Duration(
      milliseconds: AudioConstants.frameDurationMs,
    ),
    this.prefill = AudioConstants.playbackPrefillFrames,
    this.maxFrames = AudioConstants.playbackMaxFrames,
  });

  final void Function(Uint8List pcm) onFrame;

  /// Called whenever the stream is cut — the buffer ran dry (Wi-Fi hiccup) or a
  /// frame had to be thrown away because the queue overflowed. Playback uses it
  /// to fade back in, so a restart is a soft edge instead of a pop.
  final void Function()? onInterruption;
  final Duration frameDuration;
  final int prefill;
  final int maxFrames;

  final Queue<Uint8List> _queue = Queue<Uint8List>();
  Timer? _ticker;
  bool _primed = false;
  int _underruns = 0;

  int get queuedFrames => _queue.length;

  int get underrunCount => _underruns;

  bool get isPlaying => _primed;

  void start() {
    _ticker ??= Timer.periodic(frameDuration, (_) => _onTick());
  }

  void add(Uint8List pcm) {
    if (pcm.isEmpty) {
      return;
    }
    // Overflow: keep latency bounded by dropping the oldest audio.
    while (_queue.length >= maxFrames) {
      _queue.removeFirst();
      _underruns++;
      onInterruption?.call();
    }
    _queue.add(pcm);
    if (!_primed && _queue.length >= prefill) {
      _primed = true;
    }
  }

  void _onTick() {
    if (!_primed) {
      return;
    }
    if (_queue.isEmpty) {
      // Starved: stop feeding silence and wait for the buffer to re-prime.
      _primed = false;
      _underruns++;
      onInterruption?.call();
      return;
    }
    onFrame(_queue.removeFirst());
  }

  void reset() {
    _queue.clear();
    _primed = false;
    _underruns = 0;
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
    reset();
  }
}
