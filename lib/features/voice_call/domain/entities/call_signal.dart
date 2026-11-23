import 'package:equatable/equatable.dart';

/// Every control message the ESP32 router can exchange with a handset.
enum CallSignalType {
  /// `{"type":"registered","from":"User_A","id":3}` — routing id assigned.
  registered,

  /// `{"type":"incoming_call","from":"User_B","to":"User_A","id":5}`
  incomingCall,

  /// `{"type":"call_ringing"}` — optional ack that the callee is being rung.
  outgoingRinging,

  /// `{"type":"call_answered","from":"User_B","id":5}`
  callAnswered,

  /// `{"type":"call_ended","from":"User_B"}`
  callEnded,

  /// `{"type":"call_rejected","from":"User_B"}`
  callRejected,

  /// `{"type":"line_busy","message":"Please wait, the user is on another call."}`
  lineBusy,

  /// `{"type":"peer_unavailable","message":"User_B is not online."}`
  peerUnavailable,

  /// `{"type":"error","message":"..."}`
  error,

  /// Anything the app does not understand (forward-compatible ignore).
  unknown,
}

/// Immutable, framework-agnostic representation of one signalling frame.
class CallSignal extends Equatable {
  const CallSignal({
    required this.type,
    this.from,
    this.to,
    this.deviceId,
    this.message,
  });

  const CallSignal.unknown()
      : type = CallSignalType.unknown,
        from = null,
        to = null,
        deviceId = null,
        message = null;

  final CallSignalType type;
  final String? from;
  final String? to;

  /// Routing id of the peer carried by `incoming_call` / `call_answered`.
  final int? deviceId;
  final String? message;

  bool get isTerminal =>
      type == CallSignalType.callEnded ||
      type == CallSignalType.callRejected ||
      type == CallSignalType.lineBusy ||
      type == CallSignalType.peerUnavailable ||
      type == CallSignalType.error;

  @override
  List<Object?> get props => <Object?>[type, from, to, deviceId, message];
}
