import 'dart:async';
import 'dart:convert';

import '../../../../core/errors/exceptions.dart';
import '../../../../core/network/websocket_service.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/constants.dart';
import '../models/registration_message_model.dart';

/// Performs the `register` handshake against the ESP32 router.
class RegistrationRemoteDataSource {
  RegistrationRemoteDataSource({
    required WebSocketService socket,
    AppLogger? logger,
  })  : _socket = socket,
        _log = logger ?? const AppLogger('RegisterDS');

  final WebSocketService _socket;
  final AppLogger _log;

  Future<RegistrationAckModel> register({
    required String username,
    Duration timeout = NetworkConstants.registrationTimeout,
  }) async {
    await _socket.connect();

    // Subscribe *before* sending so a fast acknowledgement can never be missed.
    final ackFuture = _socket.frames
        .where((Object frame) => frame is String)
        .cast<String>()
        .map(_tryParse)
        .where((RegistrationAckModel? ack) => ack != null)
        .cast<RegistrationAckModel>()
        .firstWhere((RegistrationAckModel ack) => ack.isTerminal)
        .timeout(
          timeout,
          onTimeout: () => throw RegistrationException(
            'The router did not acknowledge registration within '
            '${timeout.inSeconds}s.',
          ),
        );

    final sent = _socket.sendJson(
      RegistrationRequestModel(username: username).toJson(),
    );
    if (!sent) {
      throw const WebSocketConnectionException(
        'Registration frame could not be sent: socket is not connected.',
      );
    }

    final ack = await ackFuture;
    if (!ack.isSuccess) {
      throw RegistrationException(
        ack.message ?? 'The router refused the username "$username".',
      );
    }
    _log.i('registered as ${ack.username ?? username} (id=${ack.deviceId})');
    return ack;
  }

  RegistrationAckModel? _tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return RegistrationAckModel.fromJson(decoded);
    } on MalformedFrameException {
      // Not a registration frame — call signalling frames flow on the same
      // socket and are ignored here.
      return null;
    } catch (error) {
      _log.d('skipped non-registration frame: $error');
      return null;
    }
  }

  Future<void> disconnect() => _socket.close();
}
