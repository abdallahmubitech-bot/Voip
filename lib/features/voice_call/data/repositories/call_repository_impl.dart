import 'dart:async';
import 'dart:typed_data';

import '../../../../core/audio/audio_route_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/constants.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/audio_check_result.dart';
import '../../domain/entities/audio_stream_stats.dart';
import '../../domain/entities/call_signal.dart';
import '../../domain/repositories/call_repository.dart';
import '../datasources/audio_hardware_source.dart';
import '../datasources/call_websocket_source.dart';
import '../datasources/pcm_chunker.dart';
import '../datasources/playback_jitter_buffer.dart';
import '../models/audio_packet_model.dart';

/// Wires signalling and the audio plane together.
///
/// Audio plane (once a call is answered):
///
/// ```text
///  mic ──► AudioHardwareSource.captureStream (~10-20 ms blocks)
///        ──► PcmChunker (40 ms / 1280-byte frames, backlog capped)
///        ──► AudioPacketModel.encode()  [peerId][pcm]
///        ──► WebSocket binary frame
///
///  WebSocket binary frame ──► strip peerId, keep frames addressed to me
///        ──► PlaybackJitterBuffer (prefill 3 frames, 40 ms ticks)
///        ──► AudioHardwareSource.feedPlayback() ──► speaker
/// ```
class CallRepositoryImpl implements CallRepository {
  CallRepositoryImpl({
    required CallWebSocketSource socketSource,
    required AudioHardwareSource audioSource,
    required AudioRouteService audioRoute,
    AppLogger? logger,
  })  : _socket = socketSource,
        _audio = audioSource,
        _route = audioRoute,
        _log = logger ?? const AppLogger('CallRepo') {
    _statusSub = _socket.statusStream.listen(_onTransportStatus);
  }

  final CallWebSocketSource _socket;
  final AudioHardwareSource _audio;
  final AudioRouteService _route;
  final AppLogger _log;

  final StreamController<Uint8List> _inboundController =
      StreamController<Uint8List>.broadcast();
  final StreamController<AudioStreamStats> _statsController =
      StreamController<AudioStreamStats>.broadcast();

  late final StreamSubscription<WebSocketStatus> _statusSub;
  StreamSubscription<Uint8List>? _inboundSub;
  StreamSubscription<Uint8List>? _captureSub;
  Timer? _statsTimer;

  PcmChunker? _chunker;
  PlaybackJitterBuffer? _jitter;

  int? _localDeviceId;
  int? _remoteDeviceId;
  bool _loudspeaker = false;
  double _peerLevel = 0;
  bool _loggedFirstOutbound = false;
  bool _loggedFirstInbound = false;
  int _idMismatchDrops = 0;
  bool _streaming = false;
  bool _muted = false;
  bool _disposed = false;

  int _framesSent = 0;
  int _framesReceived = 0;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  int _framesDropped = 0;

  @override
  Stream<CallSignal> get signals => _socket.signals;

  @override
  Stream<WebSocketStatus> get transportStatus => _socket.statusStream;

  @override
  WebSocketStatus get currentTransportStatus => _socket.status;

  @override
  Stream<Uint8List> get inboundAudio => _inboundController.stream;

  @override
  Stream<AudioStreamStats> get audioStats => _statsController.stream;

  bool get isStreaming => _streaming;

  @override
  Future<Result<Unit>> connect() async {
    try {
      await _socket.connect();
      return const Ok(Unit.instance);
    } catch (error, stackTrace) {
      return _failure(error, stackTrace);
    }
  }

  @override
  Future<Result<Unit>> makeCall({
    required String from,
    required String to,
  }) async {
    if (!_socket.status.isConnected) {
      return const Err(
        NetworkFailure(
          'Not connected to the router. Rejoin the Wi-Fi network and retry.',
        ),
      );
    }
    if (from == to) {
      return const Err(
        ServerFailure('You cannot call your own username.'),
      );
    }
    final sent = _socket.makeCall(from: from, to: to);
    return sent
        ? const Ok(Unit.instance)
        : const Err(NetworkFailure('The call request could not be sent.'));
  }

  @override
  Future<Result<Unit>> answerCall({
    required String from,
    required String to,
  }) async {
    final sent = _socket.answerCall(from: from, to: to);
    return sent
        ? const Ok(Unit.instance)
        : const Err(NetworkFailure('The answer could not be sent.'));
  }

  @override
  Future<Result<Unit>> rejectCall({
    required String from,
    required String to,
  }) async {
    final sent = _socket.rejectCall(from: from, to: to);
    return sent
        ? const Ok(Unit.instance)
        : const Err(NetworkFailure('The rejection could not be sent.'));
  }

  @override
  Future<Result<Unit>> endCall({
    required String from,
    required String to,
  }) async {
    final sent = _socket.endCall(from: from, to: to);
    await stopAudio();
    return sent
        ? const Ok(Unit.instance)
        : const Err(NetworkFailure('The hang-up could not be sent.'));
  }

  @override
  Future<Result<Unit>> startFullDuplexAudio({
    required int localDeviceId,
    required int remoteDeviceId,
  }) async {
    if (_disposed) {
      return const Err(AudioFailure('Audio engine has been disposed.'));
    }
    if (_streaming) {
      return const Ok(Unit.instance);
    }
    _localDeviceId = localDeviceId;
    _remoteDeviceId = remoteDeviceId;
    _muted = false;
    _resetCounters();

    try {
      // 1. Put the OS into phone-call mode and route to the earpiece *before*
      //    the engine opens, so capture and playback both use the voice path.
      await _route.enterCallMode();
      await _route.setLoudspeaker(enabled: false);

      _chunker = PcmChunker();
      _jitter = PlaybackJitterBuffer(onFrame: _audio.feedPlayback)..start();

      // The earpiece is quieter than media playback by design, so the pipeline
      // starts with plain unity gain and only lifts it when the operator asks
      // for the loudspeaker (see setLoudspeaker).
      _audio.playbackGain = 1.0;
      _audio.setEchoGuard(enabled: false);

      // 2. Speaker first so the first inbound frame is never discarded.
      await _audio.startPlayback();

      _inboundSub = _socket.inboundAudio.listen(
        _onInboundPacket,
        onError: (Object error, StackTrace stackTrace) =>
            _log.e('inbound audio error', error, stackTrace),
        cancelOnError: false,
      );

      final capture = await _audio.startCapture();
      _captureSub = capture.listen(
        _onCaptureChunk,
        onError: (Object error, StackTrace stackTrace) =>
            _log.e('capture error', error, stackTrace),
        cancelOnError: false,
      );

      // 3. Opening the recorder can reset the platform audio mode on some
      //    devices, which silently undoes the earpiece routing. Re-assert it now
      //    that both engines are running.
      await _route.refreshCallMode();
      await _route.setLoudspeaker(enabled: _loudspeaker);

      _streaming = true;
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _emitStats(),
      );
      _log.i('full-duplex audio streaming '
          '($localDeviceId ⇄ $remoteDeviceId)');
      return const Ok(Unit.instance);
    } catch (error, stackTrace) {
      await _teardownAudio();
      return _failure(error, stackTrace);
    }
  }

  @override
  Future<void> stopAudio() => _teardownAudio();

  @override
  Future<Result<Unit>> setMuted({required bool muted}) async {
    _muted = muted;
    _log.d('mute=$muted');
    return const Ok(Unit.instance);
  }

  @override
  Future<Result<Unit>> setLoudspeaker({required bool enabled}) async {
    try {
      _loudspeaker = enabled;
      await _route.setLoudspeaker(enabled: enabled);
      // The loudspeaker sits further from the ear, so lift the digital gain as
      // well: the limiter in AudioProcessor keeps that from clipping.
      _audio.playbackGain = enabled ? AudioConstants.speakerGain : 1.0;
      // Loudspeaker = real acoustic feedback path, so engage the software echo
      // guard. On the earpiece the platform AEC is enough and ducking would clip
      // the local talker.
      _audio.setEchoGuard(enabled: enabled);
      _log.i('loudspeaker=${enabled ? 'on' : 'off (earpiece)'}, '
          'gain=${_audio.playbackGain.toStringAsFixed(1)}x');
      return const Ok(Unit.instance);
    } catch (error, stackTrace) {
      return _failure(error, stackTrace);
    }
  }

  @override
  Future<Result<AudioCheckResult>> runAudioCheck() async {
    if (_streaming) {
      return const Err(
        ServerFailure('End the call before running the audio check.'),
      );
    }
    try {
      // Route the check through the loudspeaker so the operator can actually
      // hear their own voice, then leave the device as we found it.
      await _route.enterCallMode();
      await _route.setLoudspeaker(enabled: true);
      _audio.playbackGain = AudioConstants.speakerGain;

      final result = await _audio.runSelfTest();
      _log.i('audio check: ${result.summary}');

      return Ok(
        AudioCheckResult(
          capturePeak: result.capturePeak,
          // runSelfTest counts blocks; the domain only needs "did we get audio".
          framesCaptured: result.framesCaptured > 0
              ? result.framesCaptured
              : (result.microphoneWorks ? 1 : 0),
          playbackStarted: result.playbackStarted,
          profile: result.profile,
        ),
      );
    } catch (error, stackTrace) {
      return _failure(error, stackTrace);
    } finally {
      _audio.playbackGain = 1.0;
      await _audio.stopPlayback();
      await _route.exitCallMode();
    }
  }

  /// Capture side: mic bytes → 40 ms frames → `[peerId][pcm]` → socket.
  void _onCaptureChunk(Uint8List chunk) {
    // Muting drops samples at the source: no upload, no wasted Wi-Fi airtime.
    if (!_streaming || _muted) {
      return;
    }
    final chunker = _chunker;
    final remoteId = _remoteDeviceId;
    if (chunker == null || remoteId == null) {
      return;
    }
    for (final pcm in chunker.add(chunk)) {
      final packet = AudioPacketModel(targetDeviceId: remoteId, pcm: pcm);
      final encoded = packet.encode();
      if (_socket.sendAudio(encoded)) {
        if (!_loggedFirstOutbound) {
          _loggedFirstOutbound = true;
          _log.i('first audio frame sent: ${encoded.length} bytes to device '
              '$remoteId (profile "${_audio.activeProfileName}")');
        }
        _framesSent++;
        _bytesSent += encoded.length;
      } else {
        _framesDropped++;
      }
    }
  }

  /// Playback side: socket → verify routing byte → jitter buffer → speaker.
  void _onInboundPacket(Uint8List packet) {
    if (!_streaming || !AudioPacketModel.isPlausibleFrame(packet)) {
      return;
    }
    final targetId = AudioPacketModel.decodeTargetDeviceId(packet);
    final localId = _localDeviceId;
    // 0 is treated as broadcast so a debug firmware can stream to everyone.
    if (localId != null && targetId != localId && targetId != 0) {
      _framesDropped++;
      _idMismatchDrops++;
      // Say it once, loudly: this is what a routing-byte mismatch looks like,
      // and it is invisible in every other counter.
      if (_idMismatchDrops == 25) {
        _log.w('dropped 25 audio frames addressed to device $targetId but this '
            'handset is device $localId — check the firmware routing bytes');
      }
      return;
    }
    if (!_loggedFirstInbound) {
      _loggedFirstInbound = true;
      _log.i('first audio frame received: ${packet.length} bytes, addressed to '
          '$targetId (this handset is $localId)');
    }
    final pcm = AudioPacketModel.decodePcm(packet);
    if (pcm == null || pcm.isEmpty) {
      _framesDropped++;
      return;
    }
    _framesReceived++;
    _bytesReceived += pcm.length;

    if (!_inboundController.isClosed) {
      _inboundController.add(pcm);
    }
    _jitter?.add(pcm);
  }

  void _emitStats() {
    if (_statsController.isClosed) {
      return;
    }
    final jitter = _jitter;
    _peerLevel = _audio.playbackLevel;
    _statsController.add(
      AudioStreamStats(
        micLevel: _audio.micLevel,
        peerLevel: _peerLevel,
        captureProfile: _audio.activeProfileName,
        captureSilent: _audio.captureSilent,
        framesSent: _framesSent,
        framesReceived: _framesReceived,
        bytesSent: _bytesSent,
        bytesReceived: _bytesReceived,
        framesDropped: _framesDropped + (jitter?.underrunCount ?? 0),
        lastInboundGap: jitter == null
            ? Duration.zero
            : Duration(
                milliseconds:
                    AudioConstants.frameDurationMs * jitter.queuedFrames,
              ),
      ),
    );
  }

  void _resetCounters() {
    _framesSent = 0;
    _framesReceived = 0;
    _bytesSent = 0;
    _bytesReceived = 0;
    _framesDropped = 0;
    _idMismatchDrops = 0;
    _loggedFirstOutbound = false;
    _loggedFirstInbound = false;
  }

  Future<void> _teardownAudio() async {
    _streaming = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    await _captureSub?.cancel();
    _captureSub = null;
    await _inboundSub?.cancel();
    _inboundSub = null;
    _jitter?.stop();
    _jitter = null;
    _chunker?.reset();
    _chunker = null;
    await _audio.stopCapture();
    await _audio.stopPlayback();
    await _route.exitCallMode();
    _localDeviceId = null;
    _remoteDeviceId = null;
    _log.i('audio pipeline torn down');
  }

  void _onTransportStatus(WebSocketStatus status) {
    if (status.isConnected || !_streaming) {
      return;
    }
    // Never keep a half-open audio pipeline: the peer cannot hear us and the
    // speaker would play silence forever.
    _log.w('transport lost mid-call ($status) — stopping audio');
    unawaited(_teardownAudio());
  }

  Result<T> _failure<T>(Object error, StackTrace stackTrace) {
    _log.e('call operation failed', error, stackTrace);
    return Err<T>(mapExceptionToFailure(error, stackTrace));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _statusSub.cancel();
    await _teardownAudio();
    await _audio.dispose();
    await _route.dispose();
    await _inboundController.close();
    await _statsController.close();
  }
}
