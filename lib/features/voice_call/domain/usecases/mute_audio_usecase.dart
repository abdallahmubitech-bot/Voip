import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Toggles the microphone for the local side of a live call.
class MuteAudioUseCase {
  const MuteAudioUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({required bool muted}) =>
      _repository.setMuted(muted: muted);
}
