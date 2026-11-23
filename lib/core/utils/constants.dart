/// Compile-time constants shared by every layer.
///
/// Keeping the audio contract in one place means the ESP32 firmware and the app
/// can never silently drift apart.
abstract final class AudioConstants {
  /// Wideband speech rate required by the ESP32 I2S path.
  static const int sampleRate = 16000;

  /// Mono — one channel of 16-bit signed little-endian samples.
  static const int channelCount = 1;

  static const int bitsPerSample = 16;
  static const int bytesPerSample = bitsPerSample ~/ 8;

  /// 40 ms of audio keeps one UDP/WS frame small enough for the ESP32 stack
  /// while staying under the latency budget for a natural conversation.
  static const int frameDurationMs = 40;

  /// 16000 Hz * 0.040 s * 1 ch * 2 bytes = 1280 bytes of PCM per frame.
  static const int bytesPerFrame =
      (sampleRate * frameDurationMs ~/ 1000) * channelCount * bytesPerSample;

  /// Drop frames once this much audio is queued for sending, otherwise latency
  /// creeps upward whenever Wi-Fi jitters.
  static const int maxOutboundBacklogBytes = bytesPerFrame * 5;

  /// Number of frames buffered before playback starts (160 ms de-jitter).
  /// Slightly deeper than strictly needed on purpose: a starved buffer produces
  /// audible crackle, which is exactly what "unwanted sound" usually is.
  static const int playbackPrefillFrames = 4;

  /// Hard ceiling for the jitter buffer; beyond this the stream is stale.
  static const int playbackMaxFrames = 15;

  /// Native capture block: several 40 ms frames per read, less syscall jitter.
  static const int captureBufferBytes = 4096;

  /// Native playback ring buffer (≈64 ms at 16 kHz mono 16-bit).
  static const int playbackBufferBytes = 2048;

  /// Digital gain applied to inbound audio while the loudspeaker is on. The
  /// limiter downstream keeps this from clipping, so the call gets louder
  /// without getting harsher.
  static const double speakerGain = 2.2;
}

abstract final class NetworkConstants {
  /// SoftAP address of the ESP32 router.
  static const String defaultServerUrl = 'ws://192.168.4.1:81';

  /// Manufacturer prefix used to pre-fill the device username.
  static const String deviceUserPrefix = 'User_';

  static const Duration connectTimeout = Duration(seconds: 6);
  static const Duration heartbeatInterval = Duration(seconds: 10);
  static const Duration registrationTimeout = Duration(seconds: 8);
  static const Duration reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration reconnectMaxDelay = Duration(seconds: 8);
  static const int maxQueuedSignals = 8;
}

abstract final class CallConstants {
  static const String lineBusyMessage =
      'Please wait, the user is on another call.';
  static const Duration outgoingRingTimeout = Duration(seconds: 45);
  static const Duration incomingRingTimeout = Duration(seconds: 45);
}
