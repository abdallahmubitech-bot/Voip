import 'dart:typed_data';

import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/result.dart';
import '../entities/audio_check_result.dart';
import '../entities/audio_stream_stats.dart';
import '../entities/call_signal.dart';

/// Contract the presentation layer depends on. Implemented by
/// `CallRepositoryImpl` over WebSocket + `flutter_sound`.
abstract interface class CallRepository {
  /// Decoded JSON control frames (already mapped to entities).
  Stream<CallSignal> get signals;

  /// Real-time transport lifecycle, so the UI can react to a dropped link.
  Stream<WebSocketStatus> get transportStatus;

  /// Last known transport state (seeds `StreamBuilder.initialData`).
  WebSocketStatus get currentTransportStatus;

  /// Inbound PCM frames addressed to this handset (for level meters, etc.).
  Stream<Uint8List> get inboundAudio;

  /// Periodic counters while audio is streaming.
  Stream<AudioStreamStats> get audioStats;

  /// Opens the socket. Throws/returns [Result] failure when unreachable.
  Future<Result<Unit>> connect();

  Future<Result<Unit>> makeCall({required String from, required String to});

  Future<Result<Unit>> answerCall({required String from, required String to});

  Future<Result<Unit>> rejectCall({required String from, required String to});

  Future<Result<Unit>> endCall({required String from, required String to});

  /// Starts the full-duplex pipeline:
  ///  capture → 40 ms PCM frames → `[peerId][pcm]` → socket
  ///  socket → `[peerId][pcm]` → jitter buffer → speaker
  Future<Result<Unit>> startFullDuplexAudio({
    required int localDeviceId,
    required int remoteDeviceId,
  });

  Future<void> stopAudio();

  Future<Result<Unit>> setMuted({required bool muted});

  /// Routes call audio to the loudspeaker (true) or the earpiece (false).
  /// The earpiece is the default because it is what stops acoustic feedback.
  Future<Result<Unit>> setLoudspeaker({required bool enabled});

  /// Records two seconds from the microphone and plays it back through the
  /// speaker, to prove this handset's audio hardware works before blaming the
  /// network. Has no effect on an active call.
  Future<Result<AudioCheckResult>> runAudioCheck();

  Future<void> dispose();
}
