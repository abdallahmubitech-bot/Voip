import 'dart:convert';

import '../../../../core/errors/exceptions.dart';
import '../../domain/entities/call_signal.dart';

/// Wire ⇄ domain mapper for JSON control frames.
class CallSignalModel extends CallSignal {
  const CallSignalModel({
    required super.type,
    super.from,
    super.to,
    super.deviceId,
    super.message,
    this.rawType,
  });

  /// Parses any text frame. Unrecognised `type` values degrade to
  /// [CallSignalType.unknown] so a newer firmware never crashes the app.
  factory CallSignalModel.fromJson(Map<String, Object?> json) {
    final rawType = (json['type'] as String?)?.trim() ?? '';
    return CallSignalModel(
      type: _typeFromWire(rawType),
      rawType: rawType,
      from: _asString(json['from'] ?? json['caller'] ?? json['source']),
      to: _asString(json['to'] ?? json['callee'] ?? json['target']),
      deviceId: _asInt(json['id'] ?? json['device_id'] ?? json['peer_id']),
      message: _asString(json['message'] ?? json['reason']),
    );
  }

  factory CallSignalModel.fromRawFrame(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error, stackTrace) {
      throw MalformedFrameException(
        'Control frame is not valid JSON.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const MalformedFrameException(
        'Control frame must be a JSON object.',
      );
    }
    return CallSignalModel.fromJson(decoded);
  }

  /// The literal `type` string from the firmware (kept for logging/metrics).
  final String? rawType;

  CallSignal toEntity() => CallSignal(
        type: type,
        from: from,
        to: to,
        deviceId: deviceId,
        message: message,
      );

  static const Map<String, CallSignalType> _wireTypes = <String, CallSignalType>{
    'register': CallSignalType.registered,
    'registered': CallSignalType.registered,
    'register_ack': CallSignalType.registered,
    'incoming_call': CallSignalType.incomingCall,
    'incomingcall': CallSignalType.incomingCall,
    'call_ringing': CallSignalType.outgoingRinging,
    'ringing': CallSignalType.outgoingRinging,
    'outgoing_ringing': CallSignalType.outgoingRinging,
    'call_answered': CallSignalType.callAnswered,
    'call_answer': CallSignalType.callAnswered,
    'answered': CallSignalType.callAnswered,
    'accept_call': CallSignalType.callAnswered,
    'call_ended': CallSignalType.callEnded,
    'call_end': CallSignalType.callEnded,
    'end_call': CallSignalType.callEnded,
    'hangup': CallSignalType.callEnded,
    'call_rejected': CallSignalType.callRejected,
    'call_reject': CallSignalType.callRejected,
    'reject_call': CallSignalType.callRejected,
    'declined': CallSignalType.callRejected,
    'line_busy': CallSignalType.lineBusy,
    'linebusy': CallSignalType.lineBusy,
    'busy': CallSignalType.lineBusy,
    'peer_unavailable': CallSignalType.peerUnavailable,
    'user_unavailable': CallSignalType.peerUnavailable,
    'offline': CallSignalType.peerUnavailable,
    'not_found': CallSignalType.peerUnavailable,
    'error': CallSignalType.error,
  };

  static CallSignalType _typeFromWire(String rawType) =>
      _wireTypes[rawType.toLowerCase().replaceAll(RegExp(r'[\s-]'), '_')] ??
      CallSignalType.unknown;

  static String? _asString(Object? value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _asInt(Object? value) => switch (value) {
        null => null,
        final int v => v,
        final num v => v.toInt(),
        final String v => int.tryParse(v.trim()),
        _ => null,
      };

  @override
  String toString() =>
      'CallSignalModel(type=${rawType ?? type.name}, from=$from, '
      'to=$to, id=$deviceId, message=$message)';
}
