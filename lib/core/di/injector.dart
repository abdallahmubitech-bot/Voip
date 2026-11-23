import 'package:get_it/get_it.dart';

import '../../features/auth_registration/data/datasources/registration_remote_data_source.dart';
import '../../features/auth_registration/data/repositories/registration_repository_impl.dart';
import '../../features/auth_registration/domain/repositories/registration_repository.dart';
import '../../features/auth_registration/domain/usecases/register_device_usecase.dart';
import '../../features/auth_registration/presentation/controllers/registration_controller.dart';
import '../../features/voice_call/data/datasources/audio_hardware_source.dart';
import '../../features/voice_call/data/datasources/call_websocket_source.dart';
import '../../features/voice_call/data/repositories/call_repository_impl.dart';
import '../../features/voice_call/domain/repositories/call_repository.dart';
import '../../features/voice_call/domain/usecases/answer_call_usecase.dart';
import '../../features/voice_call/domain/usecases/connect_to_call_usecase.dart';
import '../../features/voice_call/domain/usecases/end_call_usecase.dart';
import '../../features/voice_call/domain/usecases/make_call_usecase.dart';
import '../../features/voice_call/domain/usecases/mute_audio_usecase.dart';
import '../../features/voice_call/domain/usecases/reject_call_usecase.dart';
import '../../features/voice_call/domain/usecases/run_audio_check_usecase.dart';
import '../../features/voice_call/domain/usecases/set_loudspeaker_usecase.dart';
import '../../features/voice_call/domain/usecases/stream_audio_usecase.dart';
import '../../features/voice_call/domain/usecases/watch_call_signals_usecase.dart';
import '../../features/voice_call/presentation/controllers/call_bloc.dart';
import '../audio/audio_route_service.dart';
import '../audio/ringtone_service.dart';
import '../network/websocket_config.dart';
import '../network/websocket_service.dart';
import '../utils/constants.dart';

final GetIt getIt = GetIt.instance;

/// Composition root.
///
/// One WebSocket (one TCP connection to the ESP32) is shared by both features,
/// which is exactly what the firmware expects: a single client socket per
/// handset carries registration, signalling and PCM audio.
Future<void> configureDependencies({String? serverUrl}) async {
  final config = WebSocketConfig.fromUrl(
    serverUrl ?? NetworkConstants.defaultServerUrl,
  );

  getIt
    ..registerSingleton<WebSocketConfig>(config)
    ..registerLazySingleton<WebSocketService>(
      () => WebSocketService(config: getIt<WebSocketConfig>()),
    )
    // ---- Feature 1: registration -------------------------------------------
    ..registerLazySingleton<RegistrationRemoteDataSource>(
      () => RegistrationRemoteDataSource(socket: getIt<WebSocketService>()),
    )
    ..registerLazySingleton<RegistrationRepository>(
      () => RegistrationRepositoryImpl(
        remoteDataSource: getIt<RegistrationRemoteDataSource>(),
        connectionStatus: getIt<WebSocketService>().statusStream,
      ),
    )
    ..registerLazySingleton<RegisterDeviceUseCase>(
      () => RegisterDeviceUseCase(getIt<RegistrationRepository>()),
    )
    // ---- Feature 2: voice call ---------------------------------------------
    ..registerLazySingleton<CallWebSocketSource>(
      () => CallWebSocketSource(socket: getIt<WebSocketService>()),
    )
    ..registerLazySingleton<AudioHardwareSource>(AudioHardwareSource.new)
    ..registerLazySingleton<AudioRouteService>(PlatformAudioRouteService.new)
    ..registerLazySingleton<CallRepository>(
      () => CallRepositoryImpl(
        socketSource: getIt<CallWebSocketSource>(),
        audioSource: getIt<AudioHardwareSource>(),
        audioRoute: getIt<AudioRouteService>(),
      ),
    )
    ..registerLazySingleton<ConnectToCallUseCase>(
      () => ConnectToCallUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<MakeCallUseCase>(
      () => MakeCallUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<AnswerCallUseCase>(
      () => AnswerCallUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<RejectCallUseCase>(
      () => RejectCallUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<EndCallUseCase>(
      () => EndCallUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<MuteAudioUseCase>(
      () => MuteAudioUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<SetLoudspeakerUseCase>(
      () => SetLoudspeakerUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<StreamAudioUseCase>(
      () => StreamAudioUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<RunAudioCheckUseCase>(
      () => RunAudioCheckUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<WatchCallSignalsUseCase>(
      () => WatchCallSignalsUseCase(getIt<CallRepository>()),
    )
    ..registerLazySingleton<RingtoneService>(AssetRingtoneService.new)
    // ---- Controllers (owned by the widget tree) ----------------------------
    ..registerFactory<RegistrationController>(
      () => RegistrationController(
        registerDevice: getIt<RegisterDeviceUseCase>(),
        repository: getIt<RegistrationRepository>(),
      ),
    )
    ..registerFactory<CallBloc>(
      () => CallBloc(
        connectToCall: getIt<ConnectToCallUseCase>(),
        makeCall: getIt<MakeCallUseCase>(),
        answerCall: getIt<AnswerCallUseCase>(),
        rejectCall: getIt<RejectCallUseCase>(),
        endCall: getIt<EndCallUseCase>(),
        muteAudio: getIt<MuteAudioUseCase>(),
        setLoudspeaker: getIt<SetLoudspeakerUseCase>(),
        streamAudio: getIt<StreamAudioUseCase>(),
        watchSignals: getIt<WatchCallSignalsUseCase>(),
        ringtone: getIt<RingtoneService>(),
      ),
    );
}

/// Test/reconnect helper: drops the socket and forgets every singleton.
Future<void> resetDependencies() async {
  if (getIt.isRegistered<CallRepository>()) {
    await getIt<CallRepository>().dispose();
  }
  if (getIt.isRegistered<AudioRouteService>()) {
    await getIt<AudioRouteService>().dispose();
  }
  if (getIt.isRegistered<RingtoneService>()) {
    await getIt<RingtoneService>().dispose();
  }
  if (getIt.isRegistered<WebSocketService>()) {
    await getIt<WebSocketService>().dispose();
  }
  await getIt.reset();
}
