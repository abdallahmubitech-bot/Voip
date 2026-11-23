import '../utils/constants.dart';

/// Immutable transport configuration.
///
/// The URI is injected (not hard coded in the service) so a debug build can
/// point at `ws://localhost:81` while the release build talks to the ESP32.
class WebSocketConfig {
  const WebSocketConfig({
    required this.uri,
    this.connectTimeout = NetworkConstants.connectTimeout,
    this.heartbeatInterval = NetworkConstants.heartbeatInterval,
    this.reconnectBaseDelay = NetworkConstants.reconnectBaseDelay,
    this.reconnectMaxDelay = NetworkConstants.reconnectMaxDelay,
    this.maxQueuedSignals = NetworkConstants.maxQueuedSignals,
  });

  factory WebSocketConfig.fromUrl(String url) =>
      WebSocketConfig(uri: Uri.parse(url));

  factory WebSocketConfig.esp32Default() =>
      WebSocketConfig.fromUrl(NetworkConstants.defaultServerUrl);

  final Uri uri;
  final Duration connectTimeout;
  final Duration heartbeatInterval;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;

  /// Control frames are queued (and replayed) while reconnecting. Binary audio
  /// frames never are — stale audio is worse than silence.
  final int maxQueuedSignals;

  /// Exponential backoff, capped at [reconnectMaxDelay].
  Duration reconnectDelayFor(int attempt) {
    final shift = attempt < 0 ? 0 : (attempt > 8 ? 8 : attempt);
    var millis = reconnectBaseDelay.inMilliseconds * (1 << shift);
    if (millis > reconnectMaxDelay.inMilliseconds) {
      millis = reconnectMaxDelay.inMilliseconds;
    }
    return Duration(milliseconds: millis);
  }

  @override
  String toString() => 'WebSocketConfig($uri)';
}
