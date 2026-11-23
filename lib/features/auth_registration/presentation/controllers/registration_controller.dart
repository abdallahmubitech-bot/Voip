import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/utils/app_logger.dart';
import '../../domain/entities/device_identity.dart';
import '../../domain/repositories/registration_repository.dart';
import '../../domain/usecases/register_device_usecase.dart';
import 'registration_event.dart';
import 'registration_state.dart';

/// Owns feature 1: binding this handset to a username on the ESP32 router.
class RegistrationController
    extends Bloc<RegistrationEvent, RegistrationState> {
  RegistrationController({
    required RegisterDeviceUseCase registerDevice,
    required RegistrationRepository repository,
    AppLogger? logger,
  })  : _registerDevice = registerDevice,
        _repository = repository,
        _log = logger ?? const AppLogger('RegisterBloc'),
        super(const RegistrationIdle()) {
    on<RegistrationSubmitted>(_onSubmitted);
    on<RegistrationRetried>(_onRetried);
    on<RegistrationIdentityReceived>(_onIdentityReceived);
    on<RegistrationLinkResumed>(_onLinkResumed);

    _identitySub = _repository.identityStream.listen(
      (identity) => add(RegistrationIdentityReceived(identity)),
    );
  }

  final RegisterDeviceUseCase _registerDevice;
  final RegistrationRepository _repository;
  final AppLogger _log;

  late final StreamSubscription<DeviceIdentity> _identitySub;
  String _lastUsername = '';

  Future<void> _onSubmitted(
    RegistrationSubmitted event,
    Emitter<RegistrationState> emit,
  ) async {
    _lastUsername = event.username;
    emit(const RegistrationSubmitting());
    final result = await _registerDevice(username: event.username);
    result.fold(
      onOk: (identity) => emit(RegistrationSuccess(identity)),
      onErr: (failure) => emit(
        RegistrationFailure(
          failure.message,
          isRetryable: failure.isRetryable,
        ),
      ),
    );
  }

  Future<void> _onRetried(
    RegistrationRetried event,
    Emitter<RegistrationState> emit,
  ) async {
    if (_lastUsername.isEmpty) {
      emit(const RegistrationIdle());
      return;
    }
    emit(const RegistrationSubmitting());
    final result = await _registerDevice(username: _lastUsername);
    result.fold(
      onOk: (identity) => emit(RegistrationSuccess(identity)),
      onErr: (failure) => emit(
        RegistrationFailure(
          failure.message,
          isRetryable: failure.isRetryable,
        ),
      ),
    );
  }

  void _onIdentityReceived(
    RegistrationIdentityReceived event,
    Emitter<RegistrationState> emit,
  ) {
    final identity = event.identity;
    if (state is RegistrationSuccess) {
      _log.i('identity re-assigned: id=${identity.deviceId}');
      emit(RegistrationSuccess(identity, wasReRegistered: true));
    }
  }

  void _onLinkResumed(
    RegistrationLinkResumed event,
    Emitter<RegistrationState> emit,
  ) {
    unawaited(_repository.refreshRegistration());
  }

  @override
  Future<void> close() async {
    await _identitySub.cancel();
    return super.close();
  }
}
