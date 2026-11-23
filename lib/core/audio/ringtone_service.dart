import 'package:audioplayers/audioplayers.dart';

import '../utils/app_logger.dart';

/// Ringback / ringtone plane.
///
/// Kept behind an interface and completely separate from the PCM call engine so
/// that "halt any ringing sound" on a `line_busy` signal is a single, testable
/// call — and so unit tests can swap in [SilentRingtoneService].
abstract interface class RingtoneService {
  Future<void> playRingback();

  Future<void> playIncomingRingtone();

  Future<void> stop();

  Future<void> dispose();
}

/// No-op implementation used by tests and by platforms without assets.
class SilentRingtoneService implements RingtoneService {
  const SilentRingtoneService();

  @override
  Future<void> playIncomingRingtone() async {}

  @override
  Future<void> playRingback() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Plays looping WAV assets through a dedicated [AudioPlayer].
///
/// A separate player instance is used so ring tones never contend with the
/// `flutter_sound` stream player that owns the loudspeaker during a call.
class AssetRingtoneService implements RingtoneService {
  AssetRingtoneService({AppLogger? logger})
      : _log = logger ?? const AppLogger('Ringtone');

  static const String ringbackAsset = 'audio/ringback.wav';
  static const String ringtoneAsset = 'audio/ringtone.wav';

  final AppLogger _log;
  final AudioPlayer _player = AudioPlayer(playerId: 'voip-ringtone');

  bool _disposed = false;
  String? _currentAsset;

  @override
  Future<void> playRingback() => _play(ringbackAsset);

  @override
  Future<void> playIncomingRingtone() => _play(ringtoneAsset);

  Future<void> _play(String asset) async {
    if (_disposed) {
      return;
    }
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(0.9);
      await _player.play(AssetSource(asset));
      _currentAsset = asset;
      _log.d('ringtone started: $asset');
    } catch (error, stackTrace) {
      // A missing/blocked ringtone must never break the call flow.
      _log.e('ringtone playback failed', error, stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed || _currentAsset == null) {
      return;
    }
    _currentAsset = null;
    try {
      await _player.stop();
    } catch (error) {
      _log.e('ringtone stop failed', error);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _player.dispose();
  }
}
