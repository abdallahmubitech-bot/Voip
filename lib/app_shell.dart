import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/theme/app_theme.dart';
import 'features/auth_registration/presentation/controllers/registration_controller.dart';
import 'features/auth_registration/presentation/controllers/registration_state.dart';
import 'features/auth_registration/presentation/screens/registration_screen.dart';
import 'features/voice_call/presentation/controllers/call_bloc.dart';
import 'features/voice_call/presentation/controllers/call_event.dart';
import 'features/voice_call/presentation/controllers/call_state.dart';
import 'features/voice_call/presentation/screens/active_call_screen.dart';
import 'features/voice_call/presentation/screens/dial_pad_screen.dart';
import 'features/voice_call/presentation/screens/incoming_call_screen.dart';

/// Single place that maps controller state to a screen and owns the two global
/// alerts (line-busy and call-ended).
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: <BlocListener<dynamic, dynamic>>[
        // Bind the router-assigned identity to the call controller.
        BlocListener<RegistrationController, RegistrationState>(
          listenWhen: (previous, current) =>
              current is RegistrationSuccess &&
              (previous is! RegistrationSuccess ||
                  previous.identity != current.identity),
          listener: (context, state) {
            if (state is RegistrationSuccess) {
              context
                  .read<CallBloc>()
                  .add(CallClientConfigured(state.identity));
            }
          },
        ),
        // `line_busy` → halt ringing (already done in the bloc) + native alert.
        BlocListener<CallBloc, CallState>(
          listenWhen: (previous, current) =>
              current is CallLineBusy && previous is! CallLineBusy,
          listener: (context, state) {
            if (state is CallLineBusy) {
              unawaited(_showLineBusyDialog(context, state.message));
            }
          },
        ),
        // Surface every terminal state on the dial pad.
        BlocListener<CallBloc, CallState>(
          listenWhen: (previous, current) =>
              current is CallEnded && previous is! CallEnded,
          listener: (context, state) {
            if (state is CallEnded) {
              _showCallEndedBanner(context, state);
            }
          },
        ),
      ],
      child: BlocBuilder<RegistrationController, RegistrationState>(
        builder: (context, registration) {
          if (registration is! RegistrationSuccess) {
            return const RegistrationScreen();
          }
          return BlocBuilder<CallBloc, CallState>(
            builder: (context, call) => switch (call) {
              CallIncoming() => const IncomingCallScreen(),
              CallActive() => const ActiveCallScreen(),
              _ => const DialPadScreen(),
            },
          );
        },
      ),
    );
  }

  /// Blocking, platform-adaptive alert for the busy-line feature.
  Future<void> _showLineBusyDialog(
    BuildContext context,
    String message,
  ) async {
    final bloc = context.read<CallBloc>();
    await showAdaptiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog.adaptive(
        icon: const Icon(Icons.phone_in_talk_outlined),
        title: const Text('Line busy'),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // Return to an interactive dial pad once the operator acknowledges.
    if (!bloc.isClosed) {
      bloc.add(const CallLineBusyAcknowledged());
    }
  }

  void _showCallEndedBanner(BuildContext context, CallEnded state) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(state.summary),
          backgroundColor: state.isError ? AppTheme.decline : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}
