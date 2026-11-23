import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'app_shell.dart';
import 'core/di/injector.dart';
import 'core/theme/app_theme.dart';
import 'core/network/websocket_config.dart';
import 'features/auth_registration/presentation/controllers/registration_controller.dart';
import 'features/voice_call/domain/usecases/run_audio_check_usecase.dart';
import 'features/voice_call/domain/usecases/watch_call_signals_usecase.dart';
import 'features/voice_call/presentation/controllers/call_bloc.dart';

class Esp32VoipApp extends StatelessWidget {
  const Esp32VoipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: <RepositoryProvider<dynamic>>[
        RepositoryProvider<WatchCallSignalsUseCase>(
          create: (context) => getIt<WatchCallSignalsUseCase>(),
        ),
        RepositoryProvider<RunAudioCheckUseCase>(
          create: (context) => getIt<RunAudioCheckUseCase>(),
        ),
        RepositoryProvider<WebSocketConfig>(
          create: (context) => getIt<WebSocketConfig>(),
        ),
      ],
      child: MultiBlocProvider(
        providers: <BlocProvider<dynamic>>[
          BlocProvider<RegistrationController>(
            create: (context) => getIt<RegistrationController>(),
          ),
          BlocProvider<CallBloc>(create: (context) => getIt<CallBloc>()),
        ],
        child: MaterialApp(
          title: 'Local Wi-Fi VoIP',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.system,
          home: const AppShell(),
        ),
      ),
    );
  }
}
