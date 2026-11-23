import 'package:equatable/equatable.dart';

/// The identity the ESP32 router assigned to this handset.
///
/// [deviceId] is the byte the firmware expects as the routing prefix of every
/// binary audio frame. If the router does not hand out ids, calls cannot be
/// routed and the app surfaces that as a hard error instead of guessing.
class DeviceIdentity extends Equatable {
  const DeviceIdentity({
    required this.username,
    required this.deviceId,
    required this.registeredAt,
  });

  final String username;
  final int? deviceId;
  final DateTime registeredAt;

  bool get isRoutable => deviceId != null;

  @override
  List<Object?> get props => [username, deviceId, registeredAt];
}
