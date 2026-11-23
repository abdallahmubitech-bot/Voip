import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Hangs up: notifies the router and tears down the audio pipeline.
class EndCallUseCase {
  const EndCallUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({
    required String localUser,
    required String remoteUser,
  }) =>
      _repository.endCall(from: localUser, to: remoteUser);
}
