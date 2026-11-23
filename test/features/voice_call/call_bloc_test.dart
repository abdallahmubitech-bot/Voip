import 'dart:async';
import 'dart:typed_data';

import 'package:esp32_voip/core/audio/ringtone_service.dart';
import 'package:esp32_voip/core/errors/failures.dart';
import 'package:esp32_voip/core/network/connection_status.dart';
import 'package:esp32_voip/core/utils/result.dart';
import 'package:esp32_voip/features/auth_registration/domain/entities/device_identity.dart';
import 'package:esp32_voip/features/voice_call/domain/entities/audio_check_result.dart';
import 'package:esp32_voip/features/voice_call/domain/entities/audio_stream_stats.dart';
import 'package:esp32_voip/features/voice_call/domain/entities/call_session.dart';
import 'package:esp32_voip/features/voice_call/domain/entities/call_signal.dart';
import 'package:esp32_voip/features/voice_call/domain/repositories/call_repository.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/answer_call_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/connect_to_call_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/end_call_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/make_call_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/mute_audio_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/reject_call_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/set_loudspeaker_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/stream_audio_usecase.dart';
import 'package:esp32_voip/features/voice_call/domain/usecases/watch_call_signals_usecase.dart';
import 'package:esp32_voip/features/voice_call/presentation/controllers/call_bloc.dart';
import 'package:esp32_voip/features/voice_call/presentation/controllers/call_event.dart';
import 'package:esp32_voip/features/voice_call/presentation/controllers/call_state.dart';
import 'package:flutter_test/flutter_test.dart';

final DeviceIdentity _identity = DeviceIdentity(
  username: 'User_A',
  deviceId: 1,
  registeredAt: DateTime(2026),
);

void main() {
  late FakeCallRepository repository;
  late RecordingRingtoneService ringtone;
  late CallBloc bloc;

  setUp(() {
    repository = FakeCallRepository();
    ringtone = RecordingRingtoneService();
    bloc = CallBloc(
      connectToCall: ConnectToCallUseCase(repository),
      makeCall: MakeCallUseCase(repository),
      answerCall: AnswerCallUseCase(repository),
      rejectCall: RejectCallUseCase(repository),
      endCall: EndCallUseCase(repository),
      muteAudio: MuteAudioUseCase(repository),
      setLoudspeaker: SetLoudspeakerUseCase(repository),
      streamAudio: StreamAudioUseCase(repository),
      watchSignals: WatchCallSignalsUseCase(repository),
      ringtone: ringtone,
      identity: _identity,
    );
  });

  tearDown(() async {
    await bloc.close();
    await repository.dispose();
  });

  test('line_busy halts ringing and exposes the router message', () async {
    bloc.add(const CallStarted('User_B'));
    await _waitFor(bloc, (state) => state is CallRinging);
    expect(ringtone.ringbackPlayCount, 1);

    repository.emit(
      const CallSignal(
        type: CallSignalType.lineBusy,
        message: 'Please wait, the user is on another call.',
      ),
    );

    final busy = await _waitFor(bloc, (state) => state is CallLineBusy)
        as CallLineBusy;
    expect(busy.message, 'Please wait, the user is on another call.');
    expect(ringtone.stopCount, greaterThanOrEqualTo(1));

    bloc.add(const CallLineBusyAcknowledged());
    await _waitFor(bloc, (state) => state is CallInitial);
  });

  test('answering an incoming call opens a full-duplex pipeline', () async {
    repository.emit(
      const CallSignal(
        type: CallSignalType.incomingCall,
        from: 'User_B',
        deviceId: 5,
      ),
    );
    final incoming =
        await _waitFor(bloc, (state) => state is CallIncoming) as CallIncoming;
    expect(incoming.remoteUser, 'User_B');
    expect(incoming.remoteDeviceId, 5);
    expect(ringtone.incomingPlayCount, 1);

    bloc.add(const CallAnswered());
    await _waitFor(bloc, (state) => state is CallActive);

    expect(repository.answerRequests, hasLength(1));
    expect(repository.audioStartCount, 1);
    expect(repository.lastLocalDeviceId, 1);
    expect(repository.lastRemoteDeviceId, 5);
    expect(ringtone.stopCount, greaterThanOrEqualTo(1));
  });

  test('peer answering an outgoing call switches to CallActive', () async {
    bloc.add(const CallStarted('User_B'));
    await _waitFor(bloc, (state) => state is CallRinging);

    repository.emit(
      const CallSignal(
        type: CallSignalType.callAnswered,
        from: 'User_B',
        deviceId: 5,
      ),
    );

    final active =
        await _waitFor(bloc, (state) => state is CallActive) as CallActive;
    expect(active.remoteUser, 'User_B');
    expect(active.remoteDeviceId, 5);
    expect(active.isMuted, isFalse);
    expect(repository.audioStartCount, 1);
  });

  test('a denied microphone ends the call with a permission reason', () async {
    repository.audioStartResult = const Err(
      PermissionFailure('Microphone access is blocked.'),
    );

    repository.emit(
      const CallSignal(
        type: CallSignalType.incomingCall,
        from: 'User_B',
        deviceId: 5,
      ),
    );
    await _waitFor(bloc, (state) => state is CallIncoming);

    bloc.add(const CallAnswered());
    final ended = await _waitFor(bloc, (state) => state is CallEnded)
        as CallEnded;

    expect(ended.reason, CallEndReason.permissionDenied);
    expect(ended.message, contains('Microphone'));
    expect(repository.audioStopCount, greaterThanOrEqualTo(1));
    expect(repository.endRequests, isNotEmpty);
  });

  test('losing the transport mid-call terminates the call', () async {
    repository.emit(
      const CallSignal(
        type: CallSignalType.incomingCall,
        from: 'User_B',
        deviceId: 5,
      ),
    );
    await _waitFor(bloc, (state) => state is CallIncoming);
    bloc.add(const CallAnswered());
    await _waitFor(bloc, (state) => state is CallActive);

    repository.emitTransport(WebSocketStatus.reconnecting);

    final ended = await _waitFor(bloc, (state) => state is CallEnded)
        as CallEnded;
    expect(ended.reason, CallEndReason.networkFailure);
  });

  test('calls start on the earpiece and the speaker can be toggled', () async {
    repository.emit(
      const CallSignal(
        type: CallSignalType.incomingCall,
        from: 'User_B',
        deviceId: 5,
      ),
    );
    await _waitFor(bloc, (state) => state is CallIncoming);
    bloc.add(const CallAnswered());
    final active =
        await _waitFor(bloc, (state) => state is CallActive) as CallActive;

    // A normal phone call starts on the earpiece: that is what kills feedback.
    expect(active.isLoudspeaker, isFalse);

    bloc.add(const CallLoudspeakerToggled(enabled: true));
    final loud = await _waitFor(
      bloc,
      (state) => state is CallActive && state.isLoudspeaker,
    ) as CallActive;
    expect(loud.isLoudspeaker, isTrue);
    expect(repository.loudspeaker, isTrue);

    bloc.add(const CallLoudspeakerToggled(enabled: false));
    final back = await _waitFor(
      bloc,
      (state) => state is CallActive && !state.isLoudspeaker,
    ) as CallActive;
    expect(back.isLoudspeaker, isFalse);
    expect(repository.loudspeaker, isFalse);
  });

  test('mute toggles the repository flag and the state', () async {
    repository.emit(
      const CallSignal(
        type: CallSignalType.incomingCall,
        from: 'User_B',
        deviceId: 5,
      ),
    );
    await _waitFor(bloc, (state) => state is CallIncoming);
    bloc.add(const CallAnswered());
    await _waitFor(bloc, (state) => state is CallActive);

    bloc.add(const CallMuteToggled(muted: true));
    final muted = await _waitFor(
      bloc,
      (state) => state is CallActive && state.isMuted,
    ) as CallActive;

    expect(muted.isMuted, isTrue);
    expect(repository.muted, isTrue);
  });
}

Future<CallState> _waitFor(
  CallBloc bloc,
  bool Function(CallState state) predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate(bloc.state)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for state. Last state: ${bloc.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return bloc.state;
}

class RecordingRingtoneService implements RingtoneService {
  int ringbackPlayCount = 0;
  int incomingPlayCount = 0;
  int stopCount = 0;

  @override
  Future<void> playRingback() async => ringbackPlayCount++;

  @override
  Future<void> playIncomingRingtone() async => incomingPlayCount++;

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> dispose() async {}
}

class FakeCallRepository implements CallRepository {
  final StreamController<CallSignal> _signals =
      StreamController<CallSignal>.broadcast();
  final StreamController<WebSocketStatus> _transport =
      StreamController<WebSocketStatus>.broadcast();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  final StreamController<AudioStreamStats> _stats =
      StreamController<AudioStreamStats>.broadcast();

  final List<({String from, String to})> makeRequests =
      <({String from, String to})>[];
  final List<({String from, String to})> answerRequests =
      <({String from, String to})>[];
  final List<({String from, String to})> endRequests =
      <({String from, String to})>[];
  final List<({String from, String to})> rejectRequests =
      <({String from, String to})>[];

  Result<Unit> audioStartResult = const Ok<Unit>(Unit.instance);
  int audioStartCount = 0;
  int audioStopCount = 0;
  int? lastLocalDeviceId;
  int? lastRemoteDeviceId;
  bool muted = false;
  bool loudspeaker = false;
  Result<AudioCheckResult> audioCheckResult =
      const Ok<AudioCheckResult>(AudioCheckResult(
    capturePeak: 0.4,
    framesCaptured: 30,
    playbackStarted: true,
    profile: 'voice_communication + AEC',
  ));
  int audioCheckCount = 0;
  WebSocketStatus _status = WebSocketStatus.connected;

  void emit(CallSignal signal) => _signals.add(signal);

  void emitTransport(WebSocketStatus status) {
    _status = status;
    _transport.add(status);
  }

  @override
  Stream<CallSignal> get signals => _signals.stream;

  @override
  Stream<WebSocketStatus> get transportStatus => _transport.stream;

  @override
  WebSocketStatus get currentTransportStatus => _status;

  @override
  Stream<Uint8List> get inboundAudio => _inbound.stream;

  @override
  Stream<AudioStreamStats> get audioStats => _stats.stream;

  @override
  Future<Result<Unit>> connect() async => const Ok<Unit>(Unit.instance);

  @override
  Future<Result<Unit>> makeCall({
    required String from,
    required String to,
  }) async {
    makeRequests.add((from: from, to: to));
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<Unit>> answerCall({
    required String from,
    required String to,
  }) async {
    answerRequests.add((from: from, to: to));
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<Unit>> rejectCall({
    required String from,
    required String to,
  }) async {
    rejectRequests.add((from: from, to: to));
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<Unit>> endCall({
    required String from,
    required String to,
  }) async {
    endRequests.add((from: from, to: to));
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<Unit>> startFullDuplexAudio({
    required int localDeviceId,
    required int remoteDeviceId,
  }) async {
    audioStartCount++;
    lastLocalDeviceId = localDeviceId;
    lastRemoteDeviceId = remoteDeviceId;
    return audioStartResult;
  }

  @override
  Future<void> stopAudio() async {
    audioStopCount++;
  }

  @override
  Future<Result<Unit>> setMuted({required bool muted}) async {
    this.muted = muted;
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<Unit>> setLoudspeaker({required bool enabled}) async {
    loudspeaker = enabled;
    return const Ok<Unit>(Unit.instance);
  }

  @override
  Future<Result<AudioCheckResult>> runAudioCheck() async {
    audioCheckCount++;
    return audioCheckResult;
  }

  @override
  Future<void> dispose() async {
    await _signals.close();
    await _transport.close();
    await _inbound.close();
    await _stats.close();
  }
}
