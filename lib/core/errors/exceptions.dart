/// Every exception the data layer is allowed to throw.
///
/// Repositories convert these into [AppFailure] values; nothing above the data
/// layer ever sees a raw exception from the network or the audio engine.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType($message)';
}

/// The socket could not be opened, or it dropped and stayed down.
final class WebSocketConnectionException extends AppException {
  const WebSocketConnectionException(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// The socket is open but the sink rejected a frame (usually mid-teardown).
final class WebSocketSendException extends AppException {
  const WebSocketSendException(super.message, {super.cause, super.stackTrace});
}

/// A text frame arrived that we could not decode as a call signal.
final class MalformedFrameException extends AppException {
  const MalformedFrameException(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// Registration handshake timed out or was refused by the router.
final class RegistrationException extends AppException {
  const RegistrationException(super.message, {super.cause, super.stackTrace});
}

/// The router answered with an explicit error / busy / unavailable signal.
final class ServerRejectedException extends AppException {
  const ServerRejectedException(
    super.message, {
    this.signalType,
    super.cause,
    super.stackTrace,
  });

  final String? signalType;
}

/// `RECORD_AUDIO` was denied, permanently or for this session.
final class MicrophonePermissionException extends AppException {
  const MicrophonePermissionException(super.message, {super.cause});
}

/// The native audio engine (recorder/player) refused to start or feed.
final class AudioEngineException extends AppException {
  const AudioEngineException(super.message, {super.cause, super.stackTrace});
}
