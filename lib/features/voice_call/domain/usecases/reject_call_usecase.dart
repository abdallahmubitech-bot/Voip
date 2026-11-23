import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Declines a ringing call and tells the caller why.
class RejectCallUseCase {
  const RejectCallUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({
    required String localUser,
    required String remoteUser,
  }) =>
      _repository.rejectCall(from: localUser, to: remoteUser);
}
