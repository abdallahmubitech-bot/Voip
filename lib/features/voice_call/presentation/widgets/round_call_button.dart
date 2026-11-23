import 'package:flutter/material.dart';

/// Large circular call control (accept / decline / mute / hang up).
class RoundCallButton extends StatelessWidget {
  const RoundCallButton({
    required this.icon,
    required this.onPressed,
    this.color,
    this.background,
    this.size = 68,
    this.label,
    this.semanticLabel,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? background;
  final double size;
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = IconButton.filled(
      onPressed: onPressed,
      icon: Icon(icon, size: size * 0.42),
      tooltip: semanticLabel ?? label,
      style: IconButton.styleFrom(
        backgroundColor: background ?? theme.colorScheme.primary,
        foregroundColor: color ?? Colors.white,
        disabledBackgroundColor:
            (background ?? theme.colorScheme.primary).withValues(alpha: 0.4),
        minimumSize: Size(size, size),
        maximumSize: Size(size, size),
      ),
    );
    if (label == null) {
      return button;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        button,
        const SizedBox(height: 8),
        Text(
          label!,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
