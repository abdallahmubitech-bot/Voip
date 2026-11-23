import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/audio_stream_stats.dart';
import '../controllers/call_bloc.dart';
import '../controllers/call_event.dart';
import '../controllers/call_state.dart';
import '../widgets/call_avatar.dart';
import '../widgets/round_call_button.dart';

/// Feature 2: full-duplex call in progress.
class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<CallBloc>().state;
    final active = state is CallActive ? state : null;
    final remoteUser = active?.remoteUser ?? 'Unknown';

    return PopScope(
      // A back gesture must not silently abandon a live call.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          context.read<CallBloc>().add(const CallHungUp());
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              children: <Widget>[
                const Spacer(),
                CallAvatar(username: remoteUser, size: 120),
                const SizedBox(height: 28),
                Text(
                  remoteUser,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                _CallTimer(startedAt: active?.startedAt),
                const SizedBox(height: 20),
                if (active != null)
                  _ConnectionQuality(stats: active.stats, isMuted: active.isMuted),
                if (active != null) ...<Widget>[
                  const SizedBox(height: 20),
                  _SpeakerModeTile(
                    isLoudspeaker: active.isLoudspeaker,
                    onChanged: (value) => context.read<CallBloc>().add(
                          CallLoudspeakerToggled(enabled: value),
                        ),
                  ),
                ],
                const Spacer(),
                if (active != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      RoundCallButton(
                        key: const Key('mute-button'),
                        icon: active.isMuted ? Icons.mic_off : Icons.mic,
                        background: active.isMuted
                            ? AppTheme.warning
                            : theme.colorScheme.surfaceContainerHighest,
                        color: active.isMuted
                            ? Colors.black87
                            : theme.colorScheme.onSurface,
                        label: active.isMuted ? 'Muted' : 'Mute',
                        semanticLabel: 'Toggle microphone',
                        onPressed: () => context
                            .read<CallBloc>()
                            .add(CallMuteToggled(muted: !active.isMuted)),
                      ),
                      RoundCallButton(
                        key: const Key('speaker-button'),
                        icon: active.isLoudspeaker
                            ? Icons.volume_up
                            : Icons.volume_down,
                        background: active.isLoudspeaker
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                        color: active.isLoudspeaker
                            ? Colors.white
                            : theme.colorScheme.onSurface,
                        label: active.isLoudspeaker ? 'Speaker' : 'Earpiece',
                        semanticLabel: 'Toggle loudspeaker',
                        onPressed: () => context.read<CallBloc>().add(
                              CallLoudspeakerToggled(
                                enabled: !active.isLoudspeaker,
                              ),
                            ),
                      ),
                      RoundCallButton(
                        key: const Key('hangup-button'),
                        icon: Icons.call_end,
                        background: AppTheme.decline,
                        label: 'End',
                        semanticLabel: 'End call',
                        onPressed: () =>
                            context.read<CallBloc>().add(const CallHungUp()),
                      ),
                    ],
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallTimer extends StatefulWidget {
  const _CallTimer({required this.startedAt});

  final DateTime? startedAt;

  @override
  State<_CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<_CallTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 1 Hz repaint is enough for a mm:ss readout.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    final elapsed = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Text(
      '$minutes:$seconds',
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }
}

class _ConnectionQuality extends StatelessWidget {
  const _ConnectionQuality({required this.stats, required this.isMuted});

  final AudioStreamStats stats;
  final bool isMuted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final warning = _warning();
    return Column(
      children: <Widget>[
        // Two meters answer the only question that matters during a bad call:
        // is my voice reaching the link, and is the other side's reaching me?
        _LevelMeter(
          label: 'You',
          level: isMuted ? 0 : stats.micLevel,
          icon: isMuted ? Icons.mic_off : Icons.mic,
          colour: theme.colorScheme.primary,
        ),
        const SizedBox(height: 6),
        _LevelMeter(
          label: 'Them',
          level: stats.peerLevel,
          icon: Icons.volume_up,
          colour: theme.colorScheme.secondary,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: <Widget>[
            _Chip(icon: Icons.upload, label: '${stats.framesSent} sent'),
            _Chip(icon: Icons.download, label: '${stats.framesReceived} recv'),
            if (stats.framesDropped > 0)
              _Chip(icon: Icons.warning_amber, label: '${stats.framesDropped} drop'),
            if (stats.captureProfile.isNotEmpty)
              _Chip(icon: Icons.graphic_eq, label: stats.captureProfile),
            Text('16 kHz · mono · 40 ms frames', style: style),
          ],
        ),
        if (warning != null) ...<Widget>[
          const SizedBox(height: 10),
          _DiagnosticWarning(message: warning),
        ],
      ],
    );
  }

  /// Turns the counters into one sentence the operator can act on.
  String? _warning() {
    if (stats.captureSilent) {
      return 'This phone\'s microphone is returning silence, so the other side '
          'cannot hear you. Try the Audio check on the dial pad.';
    }
    if (stats.framesSent == 0) {
      return 'Nothing is being sent yet — the microphone may still be opening.';
    }
    if (stats.framesReceived == 0) {
      return 'Audio is leaving this phone but nothing is coming back yet. Check '
          'the other handset\'s microphone.';
    }
    if (stats.peerLevel < 0.005) {
      return 'The other phone is sending silence, so its microphone is not '
          'working. Run the Audio check on that handset.';
    }
    return null;
  }
}

/// A small horizontal meter with a label and an icon.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({
    required this.label,
    required this.level,
    required this.icon,
    required this.colour,
  });

  final String label;
  final double level;
  final IconData icon;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        SizedBox(
          width: 38,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(
          width: 132,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              minHeight: 6,
              // Square-root scaling: speech peaks look tiny on a linear meter.
              value: level <= 0 ? 0 : (level.clamp(0.0, 1.0) * 3).clamp(0.0, 1.0),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(colour),
            ),
          ),
        ),
      ],
    );
  }
}

class _DiagnosticWarning extends StatelessWidget {
  const _DiagnosticWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The loudspeaker control, spelled out.
///
/// The icon row alone was too easy to miss: this tile says in words who can
/// hear the call, which is the whole point of the feature.
class _SpeakerModeTile extends StatelessWidget {
  const _SpeakerModeTile({
    required this.isLoudspeaker,
    required this.onChanged,
  });

  final bool isLoudspeaker;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('speaker-mode-tile'),
      color: isLoudspeaker
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onChanged(!isLoudspeaker),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: <Widget>[
              Icon(
                isLoudspeaker ? Icons.volume_up : Icons.phone_in_talk,
                color: isLoudspeaker
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      isLoudspeaker ? 'Loudspeaker on' : 'Earpiece',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      isLoudspeaker
                          ? 'Everyone nearby can hear the call'
                          : 'Only you can hear the call',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const Key('speaker-mode-switch'),
                value: isLoudspeaker,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
