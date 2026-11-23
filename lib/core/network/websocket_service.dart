import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../errors/exceptions.dart';
import '../utils/app_logger.dart';
import 'connection_status.dart';
import 'websocket_config.dart';

/// Transport-only WebSocket client shared by every feature.
///
/// Responsibilities:
///  * open/close an [IOWebSocketChannel] against the ESP32 router,
///  * keep it alive with native ping frames,
///  * auto-reconnect with exponential backoff,
///  * demux the two frame kinds the router speaks:
///      - `String` frames  -> JSON call signals
///      - `List<int>` frames -> raw binary audio packets
///
/// It deliberately knows nothing about calls or registration; features
/// subscribe to [frames] / [statusStream].
class WebSocketService {
  WebSocketService({
    required this.config,
    AppLogger? logger,
  }) : _log = logger ?? const AppLogger('WS');

  final WebSocketConfig config;
  final AppLogger _log;

  final StreamController<Object> _frameController =
      StreamController<Object>.broadcast();
  final StreamController<WebSocketStatus> _statusController =
      StreamController<WebSocketStatus>.broadcast();
  final List<String> _queuedSignals = <String>[];

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  WebSocketStatus _status = WebSocketStatus.disconnected;
  int _attempt = 0;
  bool _disposed = false;
  bool _closedByUser = false;

  /// Every text frame (as [String]) and binary frame (as [Uint8List]).
  Stream<Object> get frames => _frameController.stream;

  Stream<WebSocketStatus> get statusStream => _statusController.stream;

  WebSocketStatus get status => _status;

  /// Opens the socket. Throws [WebSocketConnectionException] when the *first*
  /// attempt fails so the UI can surface a real error immediately; subsequent
  /// attempts are retried in the background.
  Future<void> connect() async {
    if (_disposed) {
      throw const WebSocketConnectionException(
        'WebSocketService has already been disposed.',
      );
    }
    _closedByUser = false;
    if (_status.isConnected) {
      return;
    }
    _reconnectTimer?.cancel();
    _attempt = 0;
    final opened = await _open(allowRetry: true);
    if (!opened) {
      throw WebSocketConnectionException(
        'Could not reach the router at ${config.uri}. '
        'Check that you are joined to the ESP32 Wi-Fi network.',
      );
    }
  }

  /// Force a reconnect after the app returns from the background, etc.
  Future<void> reconnectNow() async {
    if (_disposed) {
      return;
    }
    _reconnectTimer?.cancel();
    _attempt = 0;
    await _teardownSocket();
    await _open(allowRetry: true);
  }

  /// Sends a JSON control frame. Returns `false` when the frame had to be
  /// queued because the socket is currently down.
  bool sendJson(Map<String, Object?> payload) {
    final encoded = jsonEncode(payload);
    if (!_status.isConnected) {
      if (_queuedSignals.length >= config.maxQueuedSignals) {
        _queuedSignals.removeAt(0);
      }
      _queuedSignals.add(encoded);
      _log.w('socket down, queued control frame: $encoded');
      return false;
    }
    return _rawSend(encoded, isBinary: false);
  }

  /// Sends a binary audio packet. Dropped (never queued) while disconnected.
  bool sendBinary(Uint8List packet) {
    if (!_status.isConnected) {
      return false;
    }
    return _rawSend(packet, isBinary: true);
  }

  Future<void> _teardownSocket() async {
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (error) {
        _log.d('sink close ignored: $error');
      }
    }
  }

  Future<bool> _open({required bool allowRetry}) async {
    if (_disposed) {
      return false;
    }
    _setStatus(
      _attempt == 0
          ? WebSocketStatus.connecting
          : WebSocketStatus.reconnecting,
    );

    final WebSocketChannel channel;
    try {
      channel = IOWebSocketChannel.connect(
        config.uri,
        connectTimeout: config.connectTimeout,
        pingInterval: config.heartbeatInterval,
      );
      await channel.ready.timeout(config.connectTimeout);
    } catch (error, stackTrace) {
      _log.w('open failed (attempt $_attempt): $error');
      _setStatus(WebSocketStatus.disconnected);
      if (allowRetry && !_closedByUser) {
        _scheduleReconnect();
      } else {
        _setStatus(WebSocketStatus.failed);
      }
      _log.d(stackTrace.toString());
      return false;
    }

    _channel = channel;
    _attempt = 0;
    _subscription = channel.stream.listen(
      _handleFrame,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
    _setStatus(WebSocketStatus.connected);
    _log.i('connected to ${config.uri}');
    _flushQueue();
    return true;
  }

  void _scheduleReconnect() {
    if (_disposed || _closedByUser) {
      return;
    }
    final delay = config.reconnectDelayFor(_attempt);
    _attempt++;
    _setStatus(WebSocketStatus.reconnecting);
    _log.i('reconnecting in ${delay.inMilliseconds} ms (attempt $_attempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      unawaited(_open(allowRetry: true));
    });
  }

  void _flushQueue() {
    if (_queuedSignals.isEmpty) {
      return;
    }
    final pending = List<String>.from(_queuedSignals);
    _queuedSignals.clear();
    for (final frame in pending) {
      try {
        _rawSend(frame, isBinary: false);
      } on WebSocketSendException catch (error) {
        _log.w('dropping queued frame after send failure: ${error.message}');
      }
    }
  }

  bool _rawSend(Object data, {required bool isBinary}) {
    final channel = _channel;
    if (channel == null) {
      return false;
    }
    try {
      channel.sink.add(data);
      return true;
    } catch (error, stackTrace) {
      _log.e('send failed', error, stackTrace);
      if (!isBinary) {
        throw WebSocketSendException(
          'Failed to send control frame.',
          cause: error,
          stackTrace: stackTrace,
        );
      }
      return false;
    }
  }

  void _handleFrame(Object? frame) {
    if (frame is String) {
      _frameController.add(frame);
      return;
    }
    if (frame is Uint8List) {
      _frameController.add(frame);
      return;
    }
    if (frame is ByteBuffer) {
      _frameController.add(frame.asUint8List());
      return;
    }
    if (frame is List<int>) {
      _frameController.add(Uint8List.fromList(frame));
      return;
    }
    _log.w('ignoring unsupported frame type: ${frame.runtimeType}');
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    _log.e('socket error', error, stackTrace);
  }

  void _handleSocketDone() {
    _log.w('socket closed (status=$_status, closedByUser=$_closedByUser)');
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (_closedByUser || _disposed) {
      _setStatus(WebSocketStatus.disconnected);
      return;
    }
    _scheduleReconnect();
  }

  void _setStatus(WebSocketStatus status) {
    if (_status == status || _statusController.isClosed) {
      return;
    }
    _status = status;
    _statusController.add(status);
  }

  /// Graceful close (used when the user leaves the network screen).
  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    await _teardownSocket();
    _queuedSignals.clear();
    _setStatus(WebSocketStatus.disconnected);
  }

  Future<void> dispose() async {
    _disposed = true;
    await close();
    await _frameController.close();
    await _statusController.close();
  }
}
