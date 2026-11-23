import 'dart:async';
import 'dart:typed_data';

import '../../../../core/network/connection_status.dart';
import '../../../../core/network/websocket_service.dart';
import '../../../../core/utils/app_logger.dart';
import '../models/call_signal_model.dart';

/// All call-related traffic on the shared socket:
/// JSON control frames in, JSON signals + binary PCM out.
class CallWebSocketSource {
  CallWebSocketSource({
    required WebSocketService socket,
    AppLogger? logger,
  })  : _socket = socket,
        _log = logger ?? const AppLogger('CallWS');

  final WebSocketService _socket;
  final AppLogger _log;

  Stream<CallSignalModel> get signals => _socket.frames
      .where((Object frame) => frame is String)
      .cast<String>()
      .map(_decodeOrNull)
      .where((CallSignalModel? signal) => signal != null)
      .cast<CallSignalModel>();

  Stream<Uint8List> get inboundAudio => _socket.frames
      .where((Object frame) => frame is Uint8List)
      .cast<Uint8List>();

  Stream<WebSocketStatus> get statusStream => _socket.statusStream;

  WebSocketStatus get status => _socket.status;

  Future<void> connect() => _socket.connect();

  bool makeCall({required String from, required String to}) =>
      _send(<String, Object?>{'type': 'make_call', 'from': from, 'to': to});

  bool answerCall({required String from, required String to}) =>
      _send(<String, Object?>{'type': 'call_accept', 'from': from, 'to': to});

  bool rejectCall({required String from, required String to}) => _send(
        <String, Object?>{'type': 'call_reject', 'from': from, 'to': to},
      );

  bool endCall({required String from, required String to}) =>
      _send(<String, Object?>{'type': 'end_call', 'from': from, 'to': to});

  bool sendAudio(Uint8List packet) => _socket.sendBinary(packet);

  bool _send(Map<String, Object?> payload) {
    final sent = _socket.sendJson(payload);
    if (!sent) {
      _log.w('control frame queued (socket not ready): $payload');
    }
    return sent;
  }

  CallSignalModel? _decodeOrNull(String raw) {
    try {
      final signal = CallSignalModel.fromRawFrame(raw);
      if (signal.type.name == 'unknown') {
        _log.d('ignoring unsupported signal: ${signal.rawType}');
      }
      return signal;
    } catch (error) {
      // A malformed frame must never kill the signalling stream.
      _log.e('dropping malformed control frame: $raw', error);
      return null;
    }
  }
}
