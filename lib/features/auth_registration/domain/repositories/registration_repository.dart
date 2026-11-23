import '../../../../core/network/connection_status.dart';
import '../../../../core/utils/result.dart';
import '../entities/device_identity.dart';

abstract interface class RegistrationRepository {
  /// Opens the socket if needed, sends the `register` frame and waits for the
  /// router's acknowledgement.
  Future<Result<DeviceIdentity>> register({required String username});

  /// Emits every identity the router assigns, including re-registrations after
  /// the Wi-Fi link dropped (the firmware forgets the username → id mapping
  /// when the TCP connection dies).
  Stream<DeviceIdentity> get identityStream;

  Stream<WebSocketStatus> get connectionStatus;

  DeviceIdentity? get cachedIdentity;

  /// Replays the handshake on an already-open socket.
  Future<Result<DeviceIdentity>> refreshRegistration();

  Future<void> disconnect();
}
