import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/websocket_config.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/constants.dart';
import '../controllers/registration_controller.dart';
import '../controllers/registration_event.dart';
import '../controllers/registration_state.dart';

/// Feature 1 UI: bind this handset to a username on the ESP32 router.
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key, this.initialUsername});

  final String? initialUsername;

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  late final TextEditingController _usernameController = TextEditingController(
    text: widget.initialUsername ?? _suggestUsername(),
  );
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  static String _suggestUsername() {
    final suffix = Random().nextInt(90) + 10;
    return '${NetworkConstants.deviceUserPrefix}$suffix';
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    context
        .read<RegistrationController>()
        .add(RegistrationSubmitted(_usernameController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: BlocConsumer<RegistrationController, RegistrationState>(
                listenWhen: (previous, current) => current is RegistrationFailure,
                listener: (context, state) {
                  if (state is RegistrationFailure) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(state.message),
                          backgroundColor: AppTheme.decline,
                        ),
                      );
                  }
                },
                builder: (context, state) {
                  final isBusy = state is RegistrationSubmitting;
                  return Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const _Logo(),
                        const SizedBox(height: 28),
                        Text(
                          'Join the local call network',
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Pick a username. Other handsets on the same Wi-Fi '
                          'will dial it to reach you.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _usernameController,
                          enabled: !isBusy,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          maxLength: 20,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            hintText: 'User_A',
                            counterText: '',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.length < 3) {
                              return 'Use at least 3 characters.';
                            }
                            if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(text)) {
                              return 'Letters, numbers, dot, dash, underscore.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: isBusy ? null : _submit,
                          icon: isBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.wifi_tethering),
                          label: Text(isBusy ? 'Registering…' : 'Join network'),
                        ),
                        if (state is RegistrationFailure && state.isRetryable)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: TextButton.icon(
                              onPressed: isBusy
                                  ? null
                                  : () => context
                                      .read<RegistrationController>()
                                      .add(const RegistrationRetried()),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry connection'),
                            ),
                          ),
                        const SizedBox(height: 20),
                        _RouterHint(
                          uri: context
                              .read<WebSocketConfig>()
                              .uri
                              .toString(),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: <Color>[AppTheme.brand, Color(0xFF7C3AED)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(28),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppTheme.brand.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: const Icon(Icons.phone_in_talk, color: Colors.white, size: 44),
      ),
    );
  }
}

class _RouterHint extends StatelessWidget {
  const _RouterHint({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(
          Icons.router_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Router: $uri',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
