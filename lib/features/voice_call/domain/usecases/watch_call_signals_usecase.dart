import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/result.dart';
import '../entities/audio_stream_stats.dart';
import '../entities/call_signal.dart';
import '../repositories/call_repository.dart';

/// Read-only streams consumed by the call controller.
class WatchCallSignalsUseCase {
  const WatchCallSignalsUseCase(this._repository);

  final CallRepository _repository;

  /// JSON control frames, already mapped to [CallSignal].
  Stream<CallSignal> call() => _repository.signals;

  Stream<WebSocketStatus> watchTransport() => _repository.transportStatus;

  WebSocketStatus get currentTransportStatus =>
      _repository.currentTransportStatus;

  Stream<AudioStreamStats> watchAudioStats() => _repository.audioStats;

  /// Ensures the socket is up (re-connects after a Wi-Fi blip).
  Future<Result<Unit>> ensureConnected() => _repository.connect();
}
