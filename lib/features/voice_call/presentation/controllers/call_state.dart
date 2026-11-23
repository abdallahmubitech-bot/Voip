import 'package:equatable/equatable.dart';

import '../../../../core/utils/constants.dart';
import '../../domain/entities/audio_stream_stats.dart';
import '../../domain/entities/call_session.dart';

/// Explicit, exhaustive UI states for the whole call flow.
sealed class CallState extends Equatable {
  const CallState();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Nothing in progress; the dial pad is interactive.
final class CallInitial extends CallState {
  const CallInitial();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Opening the socket / waiting for the router to accept `make_call`.
final class CallConnecting extends CallState {
  const CallConnecting();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Outgoing call is ringing on the other handset.
final class CallRinging extends CallState {
  const CallRinging({required this.remoteUser});

  final String remoteUser;

  @override
  List<Object?> get props => <Object?>[remoteUser];
}

/// Someone is calling us.
final class CallIncoming extends CallState {
  const CallIncoming({
    required this.remoteUser,
    this.remoteDeviceId,
  });

  final String remoteUser;

  /// Routing id of the caller; needed to address our outbound audio frames.
  final int? remoteDeviceId;

  @override
  List<Object?> get props => <Object?>[remoteUser, remoteDeviceId];
}

/// Two-way audio is live.
final class CallActive extends CallState {
  const CallActive({
    required this.remoteUser,
    required this.startedAt,
    this.isMuted = false,
    this.isLoudspeaker = false,
    this.remoteDeviceId,
    this.stats = const AudioStreamStats(),
  });

  final String remoteUser;
  final DateTime startedAt;
  final bool isMuted;

  /// False = earpiece (default, like a normal phone call), true = loudspeaker.
  final bool isLoudspeaker;
  final int? remoteDeviceId;
  final AudioStreamStats stats;

  Duration get elapsed => DateTime.now().difference(startedAt);

  CallActive copyWith({
    bool? isMuted,
    bool? isLoudspeaker,
    AudioStreamStats? stats,
    int? remoteDeviceId,
  }) =>
      CallActive(
        remoteUser: remoteUser,
        startedAt: startedAt,
        isMuted: isMuted ?? this.isMuted,
        isLoudspeaker: isLoudspeaker ?? this.isLoudspeaker,
        remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
        stats: stats ?? this.stats,
      );

  @override
  List<Object?> get props => <Object?>[
        remoteUser,
        startedAt,
        isMuted,
        isLoudspeaker,
        remoteDeviceId,
        stats,
      ];
}

/// The router replied `line_busy`: ringing must stop and a dialog is shown.
final class CallLineBusy extends CallState {
  const CallLineBusy({
    required this.message,
    this.remoteUser,
  });

  final String message;
  final String? remoteUser;

  @override
  List<Object?> get props => <Object?>[message, remoteUser];
}

/// Terminal state for this call; [reason] drives the copy on the dial pad.
final class CallEnded extends CallState {
  const CallEnded({required this.reason, this.message});

  final CallEndReason reason;
  final String? message;

  String get summary =>
      message ??
      switch (reason) {
        CallEndReason.localHangUp => 'Call ended',
        CallEndReason.remoteHangUp => 'The other side hung up.',
        CallEndReason.rejected => 'Call declined.',
        CallEndReason.lineBusy => CallConstants.lineBusyMessage,
        CallEndReason.peerUnavailable => 'That username is not online.',
        CallEndReason.networkFailure =>
          'Lost the connection to the ESP32 router.',
        CallEndReason.permissionDenied =>
          'Microphone access is required to place calls.',
        CallEndReason.timeout => 'No answer.',
        CallEndReason.server => 'The router rejected the call.',
        CallEndReason.unknown => 'The call ended unexpectedly.',
      };

  bool get isError =>
      reason != CallEndReason.localHangUp && reason != CallEndReason.remoteHangUp;

  @override
  List<Object?> get props => <Object?>[reason, message];
}
