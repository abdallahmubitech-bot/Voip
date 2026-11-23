import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// Controls how call audio leaves the device.
///
/// A normal phone call does three things that a naive VoIP app forgets:
///  1. puts the platform into **communication mode** so the OS applies its voice
///     processing (echo cancellation / noise suppression) to the capture path,
///  2. routes playback to the **earpiece** (the single biggest cure for feedback),
///  3. switches to the **loudspeaker** only when the user asks for it.
///
/// That requires `AudioManager` on Android, hence the small MethodChannel.
abstract interface class AudioRouteService {
  /// MODE_IN_COMMUNICATION + earpiece. Call before opening the audio engine.
  Future<void> enterCallMode();

  /// Earphone ⇄ loudspeaker.
  Future<void> setLoudspeaker({required bool enabled});

  Future<bool> isLoudspeaker();

  /// Re-asserts MODE_IN_COMMUNICATION and the current route.
  ///
  /// Opening the recorder can reset the platform audio mode, which silently
  /// undoes the earpiece routing. The repository calls this once both engines
  /// are running, and again whenever the route looks wrong.
  Future<void> refreshCallMode();

  /// MODE_NORMAL + speaker off. Call after the audio engine is torn down.
  Future<void> exitCallMode();

  Future<void> dispose();
}

/// MethodChannel-backed implementation. Silently degrades to a no-op on
/// platforms without a handler (iOS by default, tests, desktop), so the call
/// flow never breaks because routing is unavailable.
class PlatformAudioRouteService implements AudioRouteService {
  PlatformAudioRouteService({AppLogger? logger})
      : _log = logger ?? const AppLogger('AudioRoute');

  static const MethodChannel channel = MethodChannel('esp32_voip/audio_route');

  final AppLogger _log;
  bool _loudspeaker = false;
  bool _available = true;

  @override
  Future<void> enterCallMode() async {
    _loudspeaker = false;
    await _invoke<void>('enterCallMode');
  }

  @override
  Future<void> setLoudspeaker({required bool enabled}) async {
    _loudspeaker = enabled;
    await _invoke<bool>('setLoudspeaker', <String, Object?>{
      'enabled': enabled,
    });
  }

  @override
  Future<bool> isLoudspeaker() async {
    final value = await _invoke<bool>('isLoudspeaker');
    if (value != null) {
      _loudspeaker = value;
    }
    return _loudspeaker;
  }

  @override
  Future<void> refreshCallMode() async {
    await _invoke<void>('refreshCallMode', <String, Object?>{
      'loudspeaker': _loudspeaker,
    });
  }

  @override
  Future<void> exitCallMode() async {
    _loudspeaker = false;
    await _invoke<void>('exitCallMode');
  }

  @override
  Future<void> dispose() async {
    if (_loudspeaker) {
      await exitCallMode();
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!_available) {
      return null;
    }
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // No native handler on this platform — routing falls back to the OS
      // defaults, which is acceptable (and tested) behaviour.
      _available = false;
      _log.w('audio route channel unavailable on this platform');
      return null;
    } catch (error, stackTrace) {
      _log.e('audio route "$method" failed', error, stackTrace);
      return null;
    }
  }
}

/// No-op double for tests and unsupported platforms.
class NoopAudioRouteService implements AudioRouteService {
  const NoopAudioRouteService();

  @override
  Future<void> enterCallMode() async {}

  @override
  Future<void> exitCallMode() async {}

  @override
  Future<void> refreshCallMode() async {}

  @override
  Future<bool> isLoudspeaker() async => false;

  @override
  Future<void> setLoudspeaker({required bool enabled}) async {}

  @override
  Future<void> dispose() async {}
}
