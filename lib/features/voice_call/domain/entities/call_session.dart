import 'package:equatable/equatable.dart';

/// Local view of a call's lifecycle. Deliberately separate from the
/// presentation states so the domain can be unit-tested without Flutter.
enum CallStatus {
  idle,
  outgoingRinging,
  incomingRinging,
  active,
  ended,
}

enum CallDirection { outgoing, incoming }

/// Why a call stopped — drives the copy shown on the dial pad afterwards.
enum CallEndReason {
  localHangUp,
  remoteHangUp,
  rejected,
  lineBusy,
  peerUnavailable,
  networkFailure,
  permissionDenied,
  timeout,
  server,
  unknown,
}

class CallSession extends Equatable {
  const CallSession({
    required this.localUser,
    required this.remoteUser,
    required this.direction,
    required this.status,
    this.localDeviceId,
    this.remoteDeviceId,
    this.startedAt,
    this.isMuted = false,
    this.endReason,
  });

  final String localUser;
  final String remoteUser;
  final CallDirection direction;
  final CallStatus status;
  final int? localDeviceId;
  final int? remoteDeviceId;
  final DateTime? startedAt;
  final bool isMuted;
  final CallEndReason? endReason;

  bool get isLive =>
      status == CallStatus.active ||
      status == CallStatus.incomingRinging ||
      status == CallStatus.outgoingRinging;

  bool get canRouteAudio => localDeviceId != null && remoteDeviceId != null;

  CallSession copyWith({
    String? remoteUser,
    CallStatus? status,
    CallDirection? direction,
    int? localDeviceId,
    int? remoteDeviceId,
    DateTime? startedAt,
    bool? isMuted,
    CallEndReason? endReason,
  }) {
    return CallSession(
      localUser: localUser,
      remoteUser: remoteUser ?? this.remoteUser,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      localDeviceId: localDeviceId ?? this.localDeviceId,
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
      startedAt: startedAt ?? this.startedAt,
      isMuted: isMuted ?? this.isMuted,
      endReason: endReason ?? this.endReason,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        localUser,
        remoteUser,
        direction,
        status,
        localDeviceId,
        remoteDeviceId,
        startedAt,
        isMuted,
        endReason,
      ];
}
