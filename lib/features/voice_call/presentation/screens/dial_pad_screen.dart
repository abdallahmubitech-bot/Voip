import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/connection_status.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth_registration/domain/entities/device_identity.dart';
import '../../../auth_registration/presentation/controllers/registration_controller.dart';
import '../../../auth_registration/presentation/controllers/registration_state.dart';
import '../../domain/usecases/run_audio_check_usecase.dart';
import '../../domain/usecases/watch_call_signals_usecase.dart';
import '../controllers/call_bloc.dart';
import '../controllers/call_event.dart';
import '../controllers/call_state.dart';
import '../widgets/call_avatar.dart';
import '../widgets/connection_badge.dart';
import '../widgets/round_call_button.dart';

/// Feature 2 home: pick a username on the local network and dial it.
class DialPadScreen extends StatefulWidget {
  const DialPadScreen({super.key});

  @override
  State<DialPadScreen> createState() => _DialPadScreenState();
}

class _DialPadScreenState extends State<DialPadScreen> {
  final TextEditingController _calleeController = TextEditingController();
  bool _checkingAudio = false;

  @override
  void dispose() {
    _calleeController.dispose();
    super.dispose();
  }

  void _dial() {
    final target = _calleeController.text.trim();
    if (target.isEmpty) {
      _showInfo('Enter the username you want to call.');
      return;
    }
    FocusScope.of(context).unfocus();
    context.read<CallBloc>().add(CallStarted(target));
  }

  /// Records two seconds and plays it back, so a "nobody can hear me" report
  /// can be pinned on the handset or on the link before touching the network.
  Future<void> _runAudioCheck() async {
    if (_checkingAudio) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _checkingAudio = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Speak now — recording two seconds…'),
          duration: Duration(seconds: 2),
        ),
      );

    try {
      final result = await context.read<RunAudioCheckUseCase>().call();
      if (!mounted) {
        return;
      }
      final check = result.valueOrNull;
      final failure = result.failureOrNull;
      final message = check?.message ?? failure?.message ?? 'Audio check failed.';
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 6),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _checkingAudio = false);
      }
    }
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _appendKey(String key) {
    final text = _calleeController.text;
    if (key == '<') {
      if (text.isNotEmpty) {
        _calleeController.text = text.substring(0, text.length - 1);
      }
      return;
    }
    if (text.length >= 20) {
      return;
    }
    _calleeController.text = '$text$key';
    _calleeController.selection = TextSelection.collapsed(
      offset: _calleeController.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identityOf(context);
    final watchSignals = context.read<WatchCallSignalsUseCase>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local VoIP'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Audio check (record and play back)',
            onPressed: _checkingAudio ? null : _runAudioCheck,
            icon: _checkingAudio
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.hearing),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: StreamBuilder<WebSocketStatus>(
              stream: watchSignals.watchTransport(),
              initialData: watchSignals.currentTransportStatus,
              builder: (context, snapshot) =>
                  ConnectionBadge(status: snapshot.data!),
            ),
          ),
        ],
      ),
      body: BlocBuilder<CallBloc, CallState>(
        buildWhen: (previous, current) =>
            current is CallRinging ||
            current is CallConnecting ||
            previous is CallRinging ||
            previous is CallConnecting,
        builder: (context, callState) {
          return Stack(
            children: <Widget>[
              _DialBody(
                identity: identity,
                calleeController: _calleeController,
                onKey: _appendKey,
                onDial: _dial,
              ),
              if (callState is CallConnecting || callState is CallRinging)
                _OutgoingOverlay(
                  remoteUser: callState is CallRinging
                      ? callState.remoteUser
                      : _calleeController.text.trim(),
                  isConnecting: callState is CallConnecting,
                  onCancel: () =>
                      context.read<CallBloc>().add(const CallHungUp()),
                ),
            ],
          );
        },
      ),
    );
  }

  DeviceIdentity? _identityOf(BuildContext context) {
    final state = context.watch<RegistrationController>().state;
    return state is RegistrationSuccess ? state.identity : null;
  }
}

class _DialBody extends StatelessWidget {
  const _DialBody({
    required this.identity,
    required this.calleeController,
    required this.onKey,
    required this.onDial,
  });

  final DeviceIdentity? identity;
  final TextEditingController calleeController;
  final void Function(String key) onKey;
  final VoidCallback onDial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final username = identity?.username ?? '—';
    final deviceId = identity?.deviceId;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _IdentityCard(
              username: username,
              deviceId: deviceId,
            ),
            const SizedBox(height: 24),
            TextField(
              key: const Key('callee-field'),
              controller: calleeController,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              onSubmitted: (_) => onDial(),
              decoration: const InputDecoration(
                labelText: 'Call a username',
                hintText: 'User_B',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            const SizedBox(height: 20),
            _Keypad(onKey: onKey),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('dial-button'),
              onPressed: onDial,
              icon: const Icon(Icons.call),
              label: const Text('Call'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accept,
                minimumSize: const Size.fromHeight(56),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Both handsets must be joined to the ESP32 access point.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.username, required this.deviceId});

  final String username;
  final int? deviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            CallAvatar(username: username, size: 52),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    username,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    deviceId == null
                        ? 'No routing id assigned — reconnect'
                        : 'Routing id #$deviceId · 16 kHz mono',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy username',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: username));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Username copied')),
                  );
                }
              },
              icon: const Icon(Icons.copy_all_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey});

  final void Function(String key) onKey;

  static const List<List<String>> _keys = <List<String>>[
    <String>['1', '2', '3'],
    <String>['4', '5', '6'],
    <String>['7', '8', '9'],
    <String>['_', '0', '<'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (final row in _keys)
          Row(
            children: <Widget>[
              for (final key in row)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: AspectRatio(
                      aspectRatio: 2.1,
                      child: TextButton(
                        onPressed: () => onKey(key),
                        style: TextButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: key == '<'
                            ? const Icon(Icons.backspace_outlined, size: 20)
                            : Text(
                                key,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Shown over the dial pad while the router rings the callee.
class _OutgoingOverlay extends StatelessWidget {
  const _OutgoingOverlay({
    required this.remoteUser,
    required this.isConnecting,
    required this.onCancel,
  });

  final String remoteUser;
  final bool isConnecting;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.96),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CallAvatar(username: remoteUser, size: 104, isPulsing: true),
            const SizedBox(height: 32),
            Text(
              remoteUser,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isConnecting ? 'Contacting router…' : 'Ringing…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 40),
            RoundCallButton(
              icon: Icons.call_end,
              background: AppTheme.decline,
              label: 'Cancel',
              semanticLabel: 'Cancel outgoing call',
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}
