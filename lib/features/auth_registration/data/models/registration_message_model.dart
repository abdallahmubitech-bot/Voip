import 'dart:convert';

import '../../../../core/errors/exceptions.dart';

/// Outbound `register` frame.
class RegistrationRequestModel {
  const RegistrationRequestModel({required this.username});

  final String username;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'register',
        'from': username,
      };

  @override
  String toString() => 'RegistrationRequestModel($username)';
}

/// Inbound acknowledgement (`registered` / `register_ack`) or refusal (`error`).
class RegistrationAckModel {
  const RegistrationAckModel({
    required this.type,
    required this.isSuccess,
    this.username,
    this.deviceId,
    this.message,
  });

  factory RegistrationAckModel.fromJson(Map<String, Object?> json) {
    final type = (json['type'] as String?)?.toLowerCase() ?? '';
    final isAck = _successTypes.contains(type);
    final isFailure = _failureTypes.contains(type);
    if (!isAck && !isFailure) {
      throw MalformedFrameException(
        'Unsupported registration frame type "$type".',
      );
    }
    return RegistrationAckModel(
      type: type,
      isSuccess: isAck,
      username: (json['from'] ?? json['user'] ?? json['username']) as String?,
      deviceId: _parseId(json['id'] ?? json['device_id'] ?? json['deviceId']),
      message: json['message'] as String?,
    );
  }

  factory RegistrationAckModel.fromRawFrame(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error, stackTrace) {
      throw MalformedFrameException(
        'Registration frame is not valid JSON.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const MalformedFrameException(
        'Registration frame must be a JSON object.',
      );
    }
    return RegistrationAckModel.fromJson(decoded);
  }

  static const Set<String> _successTypes = <String>{
    'registered',
    'register_ack',
    'register_ok',
    'registration_success',
  };

  static const Set<String> _failureTypes = <String>{
    'error',
    'register_failed',
    'registration_failed',
    'name_taken',
    'invalid_register',
  };

  final String type;
  final bool isSuccess;
  final String? username;
  final int? deviceId;
  final String? message;

  /// True for any frame that terminates the handshake wait.
  bool get isTerminal => _successTypes.contains(type) || _failureTypes.contains(type);

  static int? _parseId(Object? raw) {
    return switch (raw) {
      null => null,
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value.trim()),
      _ => null,
    };
  }

  @override
  String toString() =>
      'RegistrationAckModel(type=$type, deviceId=$deviceId, message=$message)';
}
