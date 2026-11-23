import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../controllers/call_bloc.dart';
import '../controllers/call_event.dart';
import '../controllers/call_state.dart';
import '../widgets/call_avatar.dart';
import '../widgets/round_call_button.dart';

/// Feature 2: someone on the Wi-Fi network is calling this handset.
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CallBloc>().state;
    final caller = state is CallIncoming ? state.remoteUser : 'Unknown';

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: <Widget>[
              const Spacer(),
              CallAvatar(username: caller, size: 120, isPulsing: true),
              const SizedBox(height: 32),
              Text(
                caller,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Incoming call over local Wi-Fi',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  RoundCallButton(
                    key: const Key('decline-button'),
                    icon: Icons.call_end,
                    background: AppTheme.decline,
                    label: 'Decline',
                    semanticLabel: 'Decline call',
                    onPressed: () =>
                        context.read<CallBloc>().add(const CallRejected()),
                  ),
                  RoundCallButton(
                    key: const Key('accept-speaker-button'),
                    icon: Icons.volume_up,
                    background: AppTheme.accept,
                    label: 'Speaker',
                    semanticLabel: 'Accept call on the loudspeaker',
                    onPressed: () => context
                        .read<CallBloc>()
                        .add(const CallAnswered(speakerphone: true)),
                  ),
                  RoundCallButton(
                    key: const Key('accept-button'),
                    icon: Icons.call,
                    background: AppTheme.accept,
                    label: 'Accept',
                    semanticLabel: 'Accept call',
                    onPressed: () =>
                        context.read<CallBloc>().add(const CallAnswered()),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Accept = earpiece (only you hear it)\n'
                'Speaker = loudspeaker (everyone nearby hears it)',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
