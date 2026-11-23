import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Deterministic gradient avatar derived from the username.
class CallAvatar extends StatelessWidget {
  const CallAvatar({
    required this.username,
    this.size = 96,
    this.isPulsing = false,
    super.key,
  });

  final String username;
  final double size;
  final bool isPulsing;

  static const List<List<Color>> _palettes = <List<Color>>[
    <Color>[Color(0xFF2E7BF6), Color(0xFF7C3AED)],
    <Color>[Color(0xFF22C55E), Color(0xFF0EA5E9)],
    <Color>[Color(0xFFF59E0B), Color(0xFFEF4444)],
    <Color>[Color(0xFF8B5CF6), Color(0xFFEC4899)],
    <Color>[Color(0xFF06B6D4), Color(0xFF22C55E)],
  ];

  List<Color> get _colors =>
      _palettes[username.codeUnits.fold<int>(0, (a, b) => a + b) %
          _palettes.length];

  String get _initials {
    final clean = username.trim();
    if (clean.isEmpty) {
      return '?';
    }
    final parts = clean.split(RegExp(r'[_\-. ]+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return clean.substring(0, clean.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _colors.first.withValues(alpha: 0.35),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        _initials,
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 1,
        ),
      ),
    );

    if (!isPulsing) {
      return avatar;
    }
    return _Pulse(child: avatar);
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Container(
              width: 96 + 60 * value,
              height: 96 + 60 * value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.brand.withValues(alpha: 1 - value),
                  width: 2,
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}
