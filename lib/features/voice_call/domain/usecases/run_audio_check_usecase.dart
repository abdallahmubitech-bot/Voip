import '../../../../core/utils/result.dart';
import '../entities/audio_check_result.dart';
import '../repositories/call_repository.dart';

/// On-device microphone + speaker check ("Audio check" on the dial pad).
class RunAudioCheckUseCase {
  const RunAudioCheckUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<AudioCheckResult>> call() => _repository.runAudioCheck();
}
