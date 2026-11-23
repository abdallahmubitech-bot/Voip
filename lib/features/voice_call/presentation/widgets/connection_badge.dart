import 'package:flutter/material.dart';

import '../../../../core/network/connection_status.dart';
import '../../../../core/theme/app_theme.dart';

/// Small pill that mirrors the live WebSocket state.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({required this.status, super.key});

  final WebSocketStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (status) {
      WebSocketStatus.connected => (AppTheme.accept, 'Online'),
      WebSocketStatus.connecting => (AppTheme.warning, 'Connecting'),
      WebSocketStatus.reconnecting => (AppTheme.warning, 'Reconnecting'),
      WebSocketStatus.failed => (AppTheme.decline, 'Offline'),
      WebSocketStatus.disconnected => (AppTheme.decline, 'Offline'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
