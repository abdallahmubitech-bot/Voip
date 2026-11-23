import 'package:equatable/equatable.dart';

/// Outcome of the on-device "audio check" (record two seconds, play it back).
///
/// It exists so the operator can answer one question without any tools:
/// *is this handset's microphone and speaker working?* If the check fails, no
/// amount of network work will make a call succeed.
class AudioCheckResult extends Equatable {
  const AudioCheckResult({
    required this.capturePeak,
    required this.framesCaptured,
    required this.playbackStarted,
    required this.profile,
  });

  /// Loudest sample captured, 0…1.
  final double capturePeak;
  final int framesCaptured;
  final bool playbackStarted;

  /// Capture configuration the device accepted, e.g. `voice_communication + AEC`.
  final String profile;

  bool get microphoneWorks => capturePeak > 0.01 && framesCaptured > 5;

  bool get passed => microphoneWorks && playbackStarted;

  /// One sentence the UI can show verbatim.
  String get message {
    if (!microphoneWorks) {
      return 'No sound reached the microphone. Check the Android microphone '
          'permission, then run the check again.';
    }
    if (!playbackStarted) {
      return 'The microphone works, but the speaker could not be opened.';
    }
    return 'Microphone and speaker work (input level '
        '${(capturePeak * 100).round()}%).';
  }

  @override
  List<Object?> get props =>
      <Object?>[capturePeak, framesCaptured, playbackStarted, profile];
}
