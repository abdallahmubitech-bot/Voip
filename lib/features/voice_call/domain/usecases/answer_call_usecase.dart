import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Sends `call_accept` so the router can bridge the two audio streams.
class AnswerCallUseCase {
  const AnswerCallUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({
    required String localUser,
    required String remoteUser,
  }) =>
      _repository.answerCall(from: localUser, to: remoteUser);
}
