import '../../../../core/errors/failures.dart';
import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Validates and dispatches a `make_call` frame.
class MakeCallUseCase {
  const MakeCallUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({
    required String from,
    required String to,
  }) async {
    final caller = from.trim();
    final callee = to.trim();
    if (caller.isEmpty) {
      return const Err(
        ServerFailure("This handset hasn't registered a username yet."),
      );
    }
    if (callee.isEmpty) {
      return const Err(UnknownFailure('Enter the username you want to call.'));
    }
    if (caller.toLowerCase() == callee.toLowerCase()) {
      return const Err(
        ServerFailure('You cannot call your own username.'),
      );
    }
    return _repository.makeCall(from: caller, to: callee);
  }
}
