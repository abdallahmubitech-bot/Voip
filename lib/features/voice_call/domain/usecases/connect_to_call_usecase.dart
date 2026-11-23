import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Ensures the signalling socket is open before a call is attempted.
class ConnectToCallUseCase {
  const ConnectToCallUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call() => _repository.connect();
}
