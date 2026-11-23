import 'package:equatable/equatable.dart';

/// Live counters surfaced on the active-call screen (useful for field
/// diagnostics on a lossy Wi-Fi link).
class AudioStreamStats extends Equatable {
  const AudioStreamStats({
    this.framesSent = 0,
    this.framesReceived = 0,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.framesDropped = 0,
    this.lastInboundGap = Duration.zero,
    this.micLevel = 0,
    this.peerLevel = 0,
    this.captureProfile = '',
    this.captureSilent = false,
  });

  final int framesSent;
  final int framesReceived;
  final int bytesSent;
  final int bytesReceived;
  final int framesDropped;
  final Duration lastInboundGap;

  /// Peak level of what this phone is sending, 0…1 (live microphone meter).
  final double micLevel;

  /// Peak level of what arrived from the other phone, 0…1 (peer meter).
  final double peerLevel;

  /// Capture configuration currently in use, e.g.
  /// `voice_communication + AEC`. Empty before the call starts streaming.
  final String captureProfile;

  /// True when the microphone delivered nothing but digital silence, which
  /// means the far side cannot hear this handset no matter what the counters say.
  final bool captureSilent;

  double get outboundKbps => (bytesSent * 8) / 1000;

  /// Is the network moving audio in *both* directions right now?
  bool get isTwoWay => framesSent > 0 && framesReceived > 0;

  @override
  List<Object?> get props => <Object?>[
        framesSent,
        framesReceived,
        bytesSent,
        bytesReceived,
        framesDropped,
        lastInboundGap,
        micLevel,
        peerLevel,
        captureProfile,
        captureSilent,
      ];
}
