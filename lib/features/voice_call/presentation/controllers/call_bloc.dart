import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/audio/ringtone_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/constants.dart';
import '../../../auth_registration/domain/entities/device_identity.dart';
import '../../domain/entities/audio_stream_stats.dart';
import '../../domain/entities/call_session.dart';
import '../../domain/entities/call_signal.dart';
import '../../domain/usecases/answer_call_usecase.dart';
import '../../domain/usecases/connect_to_call_usecase.dart';
import '../../domain/usecases/end_call_usecase.dart';
import '../../domain/usecases/make_call_usecase.dart';
import '../../domain/usecases/mute_audio_usecase.dart';
import '../../domain/usecases/reject_call_usecase.dart';
import '../../domain/usecases/set_loudspeaker_usecase.dart';
import '../../domain/usecases/stream_audio_usecase.dart';
import '../../domain/usecases/watch_call_signals_usecase.dart';
import 'call_event.dart';
import 'call_state.dart';

/// Feature 2 controller: owns signalling, ringing, the audio pipeline and every
/// transition between them.
///
/// The whole call lifecycle lives here so the screens stay dumb widgets.
class CallBloc extends Bloc<CallEvent, CallState> {
  CallBloc({
    required ConnectToCallUseCase connectToCall,
    required MakeCallUseCase makeCall,
    required AnswerCallUseCase answerCall,
    required RejectCallUseCase rejectCall,
    required EndCallUseCase endCall,
    required MuteAudioUseCase muteAudio,
    required SetLoudspeakerUseCase setLoudspeaker,
    required StreamAudioUseCase streamAudio,
    required WatchCallSignalsUseCase watchSignals,
    required RingtoneService ringtone,
    DeviceIdentity? identity,
    AppLogger? logger,
  })  : _connectToCallUseCase = connectToCall,
        _makeCallUseCase = makeCall,
        _answerCallUseCase = answerCall,
        _rejectCallUseCase = rejectCall,
        _endCallUseCase = endCall,
        _muteAudioUseCase = muteAudio,
        _setLoudspeakerUseCase = setLoudspeaker,
        _streamAudioUseCase = streamAudio,
        _ringtone = ringtone,
        _identity = identity,
        _log = logger ?? const AppLogger('CallBloc'),
        super(const CallInitial()) {
    on<CallClientConfigured>(_onClientConfigured);
    on<CallStarted>(_onStarted);
    on<CallSignalReceived>(_onSignalReceived);
    on<CallAnswered>(_onAnswered);
    on<CallRejected>(_onRejected);
    on<CallHungUp>(_onHungUp);
    on<CallMuteToggled>(_onMuteToggled);
    on<CallLoudspeakerToggled>(_onLoudspeakerToggled);
    on<CallTransportChanged>(_onTransportChanged);
    on<CallLineBusyAcknowledged>(_onLineBusyAcknowledged);
    on<CallAudioStatsUpdated>(_onAudioStatsUpdated);
    on<CallRingTimedOut>(_onRingTimedOut);

    _signalSub = watchSignals.call().listen(
      (signal) => add(CallSignalReceived(signal)),
      onError: (Object error, StackTrace stackTrace) =>
          _log.e('signal stream error', error, stackTrace),
    );
    _transportSub = watchSignals.watchTransport().listen(
      (status) => add(CallTransportChanged(status)),
    );
    _statsSub = watchSignals.watchAudioStats().listen(
      (stats) => add(CallAudioStatsUpdated(stats)),
    );
  }

  final ConnectToCallUseCase _connectToCallUseCase;
  final MakeCallUseCase _makeCallUseCase;
  final AnswerCallUseCase _answerCallUseCase;
  final RejectCallUseCase _rejectCallUseCase;
  final EndCallUseCase _endCallUseCase;
  final MuteAudioUseCase _muteAudioUseCase;
  final SetLoudspeakerUseCase _setLoudspeakerUseCase;
  final StreamAudioUseCase _streamAudioUseCase;
  final RingtoneService _ringtone;
  final AppLogger _log;

  late final StreamSubscription<CallSignal> _signalSub;
  late final StreamSubscription<WebSocketStatus> _transportSub;
  late final StreamSubscription<AudioStreamStats> _statsSub;

  DeviceIdentity? _identity;
  CallSession? _session;
  Timer? _ringTimer;

  DeviceIdentity? get identity => _identity;

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  void _onClientConfigured(
    CallClientConfigured event,
    Emitter<CallState> emit,
  ) {
    _identity = event.identity;
    _log.i('client configured as ${event.identity.username} '
        '(id=${event.identity.deviceId})');
  }

  // ---------------------------------------------------------------------------
  // Outgoing call
  // ---------------------------------------------------------------------------

  Future<void> _onStarted(
    CallStarted event,
    Emitter<CallState> emit,
  ) async {
    if (_session?.isLive ?? false) {
      _log.w('ignoring dial request: a call is already in progress');
      return;
    }

    final identity = _identity;
    if (identity == null) {
      emit(
        const CallEnded(
          reason: CallEndReason.server,
          message: 'Register a username before placing a call.',
        ),
      );
      return;
    }
    final localDeviceId = identity.deviceId;
    if (localDeviceId == null) {
      emit(
        const CallEnded(
          reason: CallEndReason.server,
          message: 'The router did not assign this handset a device id, so '
              'audio cannot be routed. Reconnect and try again.',
        ),
      );
      return;
    }

    emit(const CallConnecting());

    final connected = await _connectToCallUseCase();
    if (isClosed) {
      return;
    }
    final connectFailure = connected.failureOrNull;
    if (connectFailure != null) {
      emit(
        CallEnded(
          reason: CallEndReason.networkFailure,
          message: connectFailure.message,
        ),
      );
      return;
    }

    final remoteUser = event.remoteUser.trim();
    final dialResult = await _makeCallUseCase(
      from: identity.username,
      to: remoteUser,
    );
    if (isClosed) {
      return;
    }
    final dialFailure = dialResult.failureOrNull;
    if (dialFailure != null) {
      emit(
        CallEnded(
          reason: CallEndReason.networkFailure,
          message: dialFailure.message,
        ),
      );
      return;
    }

    _session = CallSession(
      localUser: identity.username,
      remoteUser: remoteUser,
      direction: CallDirection.outgoing,
      status: CallStatus.outgoingRinging,
      localDeviceId: localDeviceId,
    );
    emit(CallRinging(remoteUser: remoteUser));
    await _ringtone.playRingback();
    _startRingTimer();
  }

  // ---------------------------------------------------------------------------
  // Inbound signalling
  // ---------------------------------------------------------------------------

  Future<void> _onSignalReceived(
    CallSignalReceived event,
    Emitter<CallState> emit,
  ) async {
    final signal = event.signal;
    switch (signal.type) {
      case CallSignalType.incomingCall:
        await _handleIncomingCall(signal, emit);
      case CallSignalType.outgoingRinging:
        // Optional ack from the firmware; the UI is already ringing.
        break;
      case CallSignalType.callAnswered:
        await _handleCallAnswered(signal, emit);
      case CallSignalType.callEnded:
        if (_session == null) {
          return;
        }
        await _terminate(emit, CallEndReason.remoteHangUp);
      case CallSignalType.callRejected:
        if (_session == null) {
          return;
        }
        await _terminate(
          emit,
          CallEndReason.rejected,
          message: signal.message ??
              '${signal.from ?? 'The other side'} declined the call.',
        );
      case CallSignalType.lineBusy:
        await _handleLineBusy(signal, emit);
      case CallSignalType.peerUnavailable:
        await _terminate(
          emit,
          CallEndReason.peerUnavailable,
          message: signal.message ?? 'That username is not online.',
        );
      case CallSignalType.error:
        await _terminate(
          emit,
          CallEndReason.server,
          message: signal.message ?? 'The router rejected the call.',
        );
      case CallSignalType.registered:
      case CallSignalType.unknown:
        break;
    }
  }

  Future<void> _handleIncomingCall(
    CallSignal signal,
    Emitter<CallState> emit,
  ) async {
    if (_session?.isLive ?? false) {
      // Already engaged here: politely tell the router so the caller is not
      // left staring at a ringing screen.
      _log.w('busy locally — auto-rejecting ${signal.from}');
      final localUser = _identity?.username ?? _session?.localUser;
      if (localUser != null && signal.from != null) {
        await _sendReject(
          localUser: localUser,
          remoteUser: signal.from!,
        );
      }
      return;
    }
    final caller = signal.from;
    if (caller == null) {
      _log.w('incoming_call frame without a caller; ignoring');
      return;
    }

    _session = CallSession(
      localUser: _identity?.username ?? '',
      remoteUser: caller,
      direction: CallDirection.incoming,
      status: CallStatus.incomingRinging,
      localDeviceId: _identity?.deviceId,
      remoteDeviceId: signal.deviceId,
    );
    emit(
      CallIncoming(remoteUser: caller, remoteDeviceId: signal.deviceId),
    );
    await _ringtone.playIncomingRingtone();
    _startRingTimer(incoming: true);
  }

  Future<void> _handleLineBusy(
    CallSignal signal,
    Emitter<CallState> emit,
  ) async {
    final remoteUser = _session?.remoteUser ?? signal.from;
    _log.i('line_busy for $remoteUser — halting ringback');
    _ringTimer?.cancel();
    _ringTimer = null;
    // 1. stop the ringback tone immediately,
    await _ringtone.stop();
    // 2. drop the pending session,
    _session = null;
    // 3. let the UI show the blocking alert with the router's message.
    emit(
      CallLineBusy(
        message: signal.message?.trim().isNotEmpty ?? false
            ? signal.message!.trim()
            : CallConstants.lineBusyMessage,
        remoteUser: remoteUser,
      ),
    );
  }

  Future<void> _handleCallAnswered(
    CallSignal signal,
    Emitter<CallState> emit,
  ) async {
    final session = _session;
    // Only an outgoing call can be answered by the peer.
    if (session == null || state is! CallRinging) {
      return;
    }

    _ringTimer?.cancel();
    _ringTimer = null;
    await _ringtone.stop();
    if (isClosed) {
      return;
    }

    final activeSession = session.copyWith(
      status: CallStatus.active,
      remoteDeviceId: signal.deviceId,
      startedAt: DateTime.now(),
    );
    _session = activeSession;
    emit(
      CallActive(
        remoteUser: activeSession.remoteUser,
        startedAt: activeSession.startedAt ?? DateTime.now(),
        remoteDeviceId: activeSession.remoteDeviceId,
      ),
    );
    await _startAudio(activeSession, emit);
  }

  // ---------------------------------------------------------------------------
  // Local call control
  // ---------------------------------------------------------------------------

  Future<void> _onAnswered(
    CallAnswered event,
    Emitter<CallState> emit,
  ) async {
    final session = _session;
    if (session == null || session.status != CallStatus.incomingRinging) {
      return;
    }
    _ringTimer?.cancel();
    _ringTimer = null;
    await _ringtone.stop();
    if (isClosed) {
      return;
    }

    final activeSession = session.copyWith(
      status: CallStatus.active,
      startedAt: DateTime.now(),
    );
    _session = activeSession;
    emit(
      CallActive(
        remoteUser: activeSession.remoteUser,
        startedAt: activeSession.startedAt ?? DateTime.now(),
        remoteDeviceId: activeSession.remoteDeviceId,
      ),
    );

    // Tell the router we are ready, then open the audio plane.
    final answered = await _answerCallUseCase(
      localUser: activeSession.localUser,
      remoteUser: activeSession.remoteUser,
    );
    if (isClosed) {
      return;
    }
    final failure = answered.failureOrNull;
    if (failure != null) {
      await _terminate(
        emit,
        CallEndReason.networkFailure,
        message: failure.message,
      );
      return;
    }
    await _startAudio(activeSession, emit);
    if (event.speakerphone) {
      // Route to the loudspeaker once the audio plane is up, so the first
      // inbound frame is already played on the right output.
      add(const CallLoudspeakerToggled(enabled: true));
    }
  }

  Future<void> _onRejected(
    CallRejected event,
    Emitter<CallState> emit,
  ) async {
    final session = _session;
    if (session == null) {
      emit(const CallInitial());
      return;
    }
    await _sendReject(
      localUser: _identity?.username ?? session.localUser,
      remoteUser: session.remoteUser,
    );
    await _terminate(emit, CallEndReason.rejected, message: 'Call declined.');
  }

  Future<void> _onHungUp(
    CallHungUp event,
    Emitter<CallState> emit,
  ) async {
    final session = _session;
    if (session == null) {
      emit(const CallInitial());
      return;
    }
    await _sendEndCall(
      localUser: _identity?.username ?? session.localUser,
      remoteUser: session.remoteUser,
    );
    await _terminate(emit, CallEndReason.localHangUp);
  }

  Future<void> _onMuteToggled(
    CallMuteToggled event,
    Emitter<CallState> emit,
  ) async {
    final current = state;
    if (current is! CallActive) {
      return;
    }
    final result = await _muteAudioUseCase(muted: event.muted);
    if (isClosed) {
      return;
    }
    final failure = result.failureOrNull;
    if (failure != null) {
      _log.e('mute toggle failed: ${failure.message}');
      return;
    }
    _session = _session?.copyWith(isMuted: event.muted);
    final latest = state;
    if (latest is CallActive) {
      emit(latest.copyWith(isMuted: event.muted));
    }
  }

  Future<void> _onLoudspeakerToggled(
    CallLoudspeakerToggled event,
    Emitter<CallState> emit,
  ) async {
    final current = state;
    if (current is! CallActive) {
      return;
    }
    final result = await _setLoudspeakerUseCase(enabled: event.enabled);
    if (isClosed) {
      return;
    }
    final failure = result.failureOrNull;
    if (failure != null) {
      _log.e('loudspeaker toggle failed: ${failure.message}');
      return;
    }
    final latest = state;
    if (latest is CallActive) {
      emit(latest.copyWith(isLoudspeaker: event.enabled));
    }
  }

  Future<void> _onTransportChanged(
    CallTransportChanged event,
    Emitter<CallState> emit,
  ) async {
    final status = event.status;
    // Only a live call cares about the transport; idle reconnects are handled
    // by WebSocketService's own backoff.
    if (status.isConnected || !(_session?.isLive ?? false)) {
      return;
    }
    _log.w('transport dropped mid-call ($status)');
    // Must be awaited inside the handler: bloc forbids emitting after it returns.
    await _terminate(
      emit,
      CallEndReason.networkFailure,
      message: 'The Wi-Fi link to the router dropped, so the call ended.',
    );
  }

  void _onLineBusyAcknowledged(
    CallLineBusyAcknowledged event,
    Emitter<CallState> emit,
  ) {
    if (state is CallLineBusy) {
      emit(const CallInitial());
    }
  }

  void _onAudioStatsUpdated(
    CallAudioStatsUpdated event,
    Emitter<CallState> emit,
  ) {
    final current = state;
    if (current is CallActive) {
      emit(current.copyWith(stats: event.stats));
    }
  }

  Future<void> _onRingTimedOut(
    CallRingTimedOut event,
    Emitter<CallState> emit,
  ) async {
    final current = state;
    final session = _session;
    if (session == null) {
      return;
    }
    if (current is CallRinging) {
      await _sendEndCall(
        localUser: _identity?.username ?? session.localUser,
        remoteUser: session.remoteUser,
      );
      await _terminate(emit, CallEndReason.timeout);
    } else if (current is CallIncoming) {
      await _sendReject(
        localUser: _identity?.username ?? session.localUser,
        remoteUser: session.remoteUser,
      );
      await _terminate(
        emit,
        CallEndReason.timeout,
        message: 'Missed call from ${session.remoteUser}.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Audio plane
  // ---------------------------------------------------------------------------

  Future<void> _startAudio(
    CallSession session,
    Emitter<CallState> emit,
  ) async {
    final localDeviceId = session.localDeviceId ?? _identity?.deviceId;
    final remoteDeviceId = session.remoteDeviceId;
    if (localDeviceId == null || remoteDeviceId == null) {
      await _sendEndCall(
        localUser: session.localUser,
        remoteUser: session.remoteUser,
      );
      await _terminate(
        emit,
        CallEndReason.server,
        message: 'The router did not share the device ids needed to route '
            'audio for this call.',
      );
      return;
    }

    final result = await _streamAudioUseCase.start(
      localDeviceId: localDeviceId,
      remoteDeviceId: remoteDeviceId,
    );
    if (isClosed) {
      return;
    }
    final failure = result.failureOrNull;
    if (failure == null) {
      return;
    }
    _log.e('audio pipeline failed: ${failure.message}');
    await _sendEndCall(
      localUser: session.localUser,
      remoteUser: session.remoteUser,
    );
    await _terminate(
      emit,
      failure is PermissionFailure
          ? CallEndReason.permissionDenied
          : CallEndReason.unknown,
      message: failure.message,
    );
  }

  /// Stops ringing, tears the pipeline down and emits the terminal state.
  Future<void> _terminate(
    Emitter<CallState> emit,
    CallEndReason reason, {
    String? message,
  }) async {
    _ringTimer?.cancel();
    _ringTimer = null;
    _session = null;
    await _ringtone.stop();
    await _streamAudioUseCase.stop();
    if (isClosed) {
      return;
    }
    _log.i('call terminated: ${reason.name}${message == null ? '' : ' ($message)'}');
    emit(CallEnded(reason: reason, message: message));
  }

  /// Best-effort `end_call` frame; a failure here must not block teardown.
  Future<void> _sendEndCall({
    required String localUser,
    required String remoteUser,
  }) async {
    final failure = (await _endCallUseCase(
      localUser: localUser,
      remoteUser: remoteUser,
    ))
        .failureOrNull;
    if (failure != null) {
      _log.w('hang-up frame not delivered: ${failure.message}');
    }
  }

  Future<void> _sendReject({
    required String localUser,
    required String remoteUser,
  }) async {
    final failure = (await _rejectCallUseCase(
      localUser: localUser,
      remoteUser: remoteUser,
    ))
        .failureOrNull;
    if (failure != null) {
      _log.w('reject frame not delivered: ${failure.message}');
    }
  }

  void _startRingTimer({bool incoming = false}) {
    _ringTimer?.cancel();
    _ringTimer = Timer(
      incoming
          ? CallConstants.incomingRingTimeout
          : CallConstants.outgoingRingTimeout,
      () {
        if (!isClosed) {
          add(const CallRingTimedOut());
        }
      },
    );
  }

  @override
  Future<void> close() async {
    _ringTimer?.cancel();
    await _ringtone.stop();
    await _streamAudioUseCase.stop();
    await _signalSub.cancel();
    await _transportSub.cancel();
    await _statsSub.cancel();
    return super.close();
  }
}
