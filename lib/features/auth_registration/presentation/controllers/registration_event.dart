import 'package:equatable/equatable.dart';

import '../../domain/entities/device_identity.dart';

sealed class RegistrationEvent extends Equatable {
  const RegistrationEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Fired when the operator taps "Join network".
final class RegistrationSubmitted extends RegistrationEvent {
  const RegistrationSubmitted(this.username);

  final String username;

  @override
  List<Object?> get props => <Object?>[username];
}

/// Retry after a transport failure without re-typing the username.
final class RegistrationRetried extends RegistrationEvent {
  const RegistrationRetried();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Internal: the repository assigned (or re-assigned) a routing id.
final class RegistrationIdentityReceived extends RegistrationEvent {
  const RegistrationIdentityReceived(this.identity);

  final DeviceIdentity identity;

  @override
  List<Object?> get props => <Object?>[identity];
}

final class RegistrationLinkResumed extends RegistrationEvent {
  const RegistrationLinkResumed();

  @override
  List<Object?> get props => const <Object?>[];
}
