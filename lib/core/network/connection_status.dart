/// Lifecycle of the shared WebSocket transport.
enum WebSocketStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed;

  bool get isConnected => this == WebSocketStatus.connected;

  bool get isNegotiating =>
      this == WebSocketStatus.connecting || this == WebSocketStatus.reconnecting;

  /// True while the socket is either up or actively trying to come back —
  /// used to decide whether a "line dropped" event is really fatal.
  bool get isTransient => isNegotiating;
}
