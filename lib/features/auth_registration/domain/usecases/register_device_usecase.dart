import '../../../../core/errors/failures.dart';
import '../../../../core/utils/result.dart';
import '../entities/device_identity.dart';
import '../repositories/registration_repository.dart';

/// Validates the operator-supplied username before it reaches the router.
class RegisterDeviceUseCase {
  const RegisterDeviceUseCase(this._repository);

  static const int minLength = 3;
  static const int maxLength = 20;

  final RegistrationRepository _repository;

  Future<Result<DeviceIdentity>> call({required String username}) async {
    final trimmed = username.trim();
    final validationError = _validate(trimmed);
    if (validationError != null) {
      return Err(validationError);
    }
    return _repository.register(username: trimmed);
  }

  AppFailure? _validate(String username) {
    if (username.isEmpty) {
      return const UnknownFailure('Enter a username to register.');
    }
    if (username.length < minLength) {
      return const UnknownFailure(
        'Username must be at least $minLength characters.',
      );
    }
    if (username.length > maxLength) {
      return const UnknownFailure(
        'Username must be $maxLength characters or fewer.',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(username)) {
      return const UnknownFailure(
        'Use letters, numbers, dot, dash or underscore only.',
      );
    }
    return null;
  }
}
