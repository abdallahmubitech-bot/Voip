import '../../../../core/utils/result.dart';
import '../repositories/call_repository.dart';

/// Switches call audio between the earpiece and the loudspeaker.
///
/// Kept as a use case (not a raw repository call) so the presentation layer
/// stays declarative: the UI emits an intent, the controller applies it.
class SetLoudspeakerUseCase {
  const SetLoudspeakerUseCase(this._repository);

  final CallRepository _repository;

  Future<Result<Unit>> call({required bool enabled}) =>
      _repository.setLoudspeaker(enabled: enabled);
}
