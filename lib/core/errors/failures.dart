import 'exceptions.dart';

/// User-facing error type. Messages are safe to show in a dialog or snackbar.
sealed class AppFailure {
  const AppFailure(this.message, {this.cause, this.isRetryable = true});

  final String message;
  final Object? cause;
  final bool isRetryable;

  @override
  String toString() => '$runtimeType($message)';
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure(
    super.message, {
    super.cause,
    super.isRetryable = true,
  });
}

final class PermissionFailure extends AppFailure {
  const PermissionFailure(
    super.message, {
    super.cause,
  }) : super(isRetryable: false);
}

final class AudioFailure extends AppFailure {
  const AudioFailure(
    super.message, {
    super.cause,
  });
}

final class ServerFailure extends AppFailure {
  const ServerFailure(
    super.message, {
    this.signalType,
    super.cause,
    super.isRetryable = false,
  });

  final String? signalType;
}

final class UnknownFailure extends AppFailure {
  const UnknownFailure(
    super.message, {
    super.cause,
  });
}

/// Single choke point that translates data-layer exceptions into failures.
AppFailure mapExceptionToFailure(Object error, [StackTrace? stackTrace]) {
  if (error is AppFailure) {
    return error;
  }
  return switch (error) {
    MicrophonePermissionException(:final message) => PermissionFailure(
        message,
        cause: error,
      ),
    AudioEngineException(:final message) => AudioFailure(
        message,
        cause: error,
      ),
    WebSocketConnectionException(:final message) => NetworkFailure(
        message,
        cause: error,
      ),
    WebSocketSendException(:final message) => NetworkFailure(
        message,
        cause: error,
      ),
    MalformedFrameException(:final message) => ServerFailure(
        message,
        cause: error,
      ),
    RegistrationException(:final message) => ServerFailure(
        message,
        cause: error,
      ),
    ServerRejectedException(:final message, :final signalType) => ServerFailure(
        message,
        signalType: signalType,
        cause: error,
      ),
    _ => UnknownFailure(
        'Unexpected error: $error',
        cause: error,
      ),
  };
}
