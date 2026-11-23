import 'package:equatable/equatable.dart';

import '../../../auth_registration/domain/entities/device_identity.dart';
import '../../domain/entities/audio_stream_stats.dart';
import '../../domain/entities/call_signal.dart';
import '../../../../core/network/connection_status.dart';

sealed class CallEvent extends Equatable {
  const CallEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Binds the identity assigned by feature 1 to the call controller.
final class CallClientConfigured extends CallEvent {
  const CallClientConfigured(this.identity);

  final DeviceIdentity identity;

  @override
  List<Object?> get props => <Object?>[identity];
}

/// Operator pressed "Call" on the dial pad.
final class CallStarted extends CallEvent {
  const CallStarted(this.remoteUser);

  final String remoteUser;

  @override
  List<Object?> get props => <Object?>[remoteUser];
}

/// Internal: a JSON control frame arrived from the router.
final class CallSignalReceived extends CallEvent {
  const CallSignalReceived(this.signal);

  final CallSignal signal;

  @override
  List<Object?> get props => <Object?>[signal];
}

/// Operator pressed "Accept" on the incoming-call screen.
final class CallAnswered extends CallEvent {
  const CallAnswered();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Operator pressed "Decline".
final class CallRejected extends CallEvent {
  const CallRejected();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Operator pressed the red button (or the OS back gesture).
final class CallHungUp extends CallEvent {
  const CallHungUp();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Speaker ⇄ earpiece.
final class CallLoudspeakerToggled extends CallEvent {
  const CallLoudspeakerToggled({required this.enabled});

  final bool enabled;

  @override
  List<Object?> get props => <Object?>[enabled];
}

final class CallMuteToggled extends CallEvent {
  const CallMuteToggled({required this.muted});

  final bool muted;

  @override
  List<Object?> get props => <Object?>[muted];
}

/// Transport lifecycle (connect/reconnect/drop).
final class CallTransportChanged extends CallEvent {
  const CallTransportChanged(this.status);

  final WebSocketStatus status;

  @override
  List<Object?> get props => <Object?>[status];
}

/// The "line busy" alert was dismissed — fall back to the dial pad.
final class CallLineBusyAcknowledged extends CallEvent {
  const CallLineBusyAcknowledged();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Internal: 1 Hz audio counters from the repository.
final class CallAudioStatsUpdated extends CallEvent {
  const CallAudioStatsUpdated(this.stats);

  final AudioStreamStats stats;

  @override
  List<Object?> get props => <Object?>[stats];
}

/// Internal: 45 s elapsed without the peer answering.
final class CallRingTimedOut extends CallEvent {
  const CallRingTimedOut();

  @override
  List<Object?> get props => const <Object?>[];
}
