import 'package:equatable/equatable.dart';

import '../../domain/entities/device_identity.dart';

sealed class RegistrationState extends Equatable {
  const RegistrationState();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Waiting for the operator to submit a username.
final class RegistrationIdle extends RegistrationState {
  const RegistrationIdle();

  @override
  List<Object?> get props => const <Object?>[];
}

final class RegistrationSubmitting extends RegistrationState {
  const RegistrationSubmitting();

  @override
  List<Object?> get props => const <Object?>[];
}

final class RegistrationSuccess extends RegistrationState {
  const RegistrationSuccess(this.identity, {this.wasReRegistered = false});

  final DeviceIdentity identity;

  /// True when the identity arrived after a reconnect rather than a first join.
  final bool wasReRegistered;

  @override
  List<Object?> get props => <Object?>[identity, wasReRegistered];
}

final class RegistrationFailure extends RegistrationState {
  const RegistrationFailure(this.message, {this.isRetryable = true});

  final String message;
  final bool isRetryable;

  @override
  List<Object?> get props => <Object?>[message, isRetryable];
}
