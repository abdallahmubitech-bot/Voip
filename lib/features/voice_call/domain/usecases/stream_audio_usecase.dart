import '../../../../core/errors/failures.dart';
import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Starts / stops the full-duplex PCM stream for an answered call.
class StreamAudioUseCase {
  const StreamAudioUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> start({
    required int localDeviceId,
    required int remoteDeviceId,
  }) {
    if (localDeviceId < 0 || remoteDeviceId < 0) {
      return Future<Result<Unit>>.value(
        const Err(
          ServerFailure(
            'The router did not share a usable device id for this call.',
          ),
        ),
      );
    }
    return _repository.startFullDuplexAudio(
      localDeviceId: localDeviceId,
      remoteDeviceId: remoteDeviceId,
    );
  }

  Future<void> stop() => _repository.stopAudio();
}
