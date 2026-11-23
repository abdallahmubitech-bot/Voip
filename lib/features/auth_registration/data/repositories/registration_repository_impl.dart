import 'dart:async';

import '../../../../core/errors/failures.dart';
import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/device_identity.dart';
import '../../domain/repositories/registration_repository.dart';
import '../datasources/registration_remote_data_source.dart';

class RegistrationRepositoryImpl implements RegistrationRepository {
  RegistrationRepositoryImpl({
    required RegistrationRemoteDataSource remoteDataSource,
    required Stream<WebSocketStatus> connectionStatus,
    AppLogger? logger,
  })  : _remote = remoteDataSource,
        _connectionStatus = connectionStatus,
        _log = logger ?? const AppLogger('RegisterRepo') {
    _statusSub = _connectionStatus.listen(_onStatusChanged);
  }

  final RegistrationRemoteDataSource _remote;
  final Stream<WebSocketStatus> _connectionStatus;
  final AppLogger _log;

  final StreamController<DeviceIdentity> _identityController =
      StreamController<DeviceIdentity>.broadcast();

  late final StreamSubscription<WebSocketStatus> _statusSub;
  WebSocketStatus _lastStatus = WebSocketStatus.disconnected;
  String? _username;
  DeviceIdentity? _cached;
  bool _reRegistering = false;

  @override
  Stream<DeviceIdentity> get identityStream => _identityController.stream;

  @override
  Stream<WebSocketStatus> get connectionStatus => _connectionStatus;

  @override
  DeviceIdentity? get cachedIdentity => _cached;

  @override
  Future<Result<DeviceIdentity>> register({required String username}) async {
    _username = username;
    return _performHandshake(username);
  }

  @override
  Future<Result<DeviceIdentity>> refreshRegistration() async {
    final username = _username;
    if (username == null) {
      return const Err(
        ServerFailure('No username has been registered yet.'),
      );
    }
    return _performHandshake(username);
  }

  Future<Result<DeviceIdentity>> _performHandshake(String username) async {
    try {
      final ack = await _remote.register(username: username);
      final identity = DeviceIdentity(
        username: ack.username ?? username,
        deviceId: ack.deviceId,
        registeredAt: DateTime.now(),
      );
      _cached = identity;
      if (!_identityController.isClosed) {
        _identityController.add(identity);
      }
      if (!identity.isRoutable) {
        _log.w('router did not assign a device id; calls will be refused');
      }
      return Ok(identity);
    } catch (error, stackTrace) {
      _log.e('registration failed', error, stackTrace);
      return Err(mapExceptionToFailure(error, stackTrace));
    }
  }

  void _onStatusChanged(WebSocketStatus status) {
    final previous = _lastStatus;
    _lastStatus = status;
    final reconnected = status.isConnected && previous != status &&
        (previous == WebSocketStatus.reconnecting ||
            previous == WebSocketStatus.disconnected);

    if (!reconnected || _cached == null || _reRegistering) {
      return;
    }
    // The firmware drops the session when the socket closes, so replay the
    // handshake to obtain a fresh routing id.
    _reRegistering = true;
    unawaited(
      refreshRegistration().whenComplete(() => _reRegistering = false),
    );
  }

  @override
  Future<void> disconnect() async {
    await _statusSub.cancel();
    await _remote.disconnect();
    await _identityController.close();
  }
}
