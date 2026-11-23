import 'dart:typed_data';

import '../../../../core/utils/constants.dart';

/// One binary audio frame on the wire:
///
/// ```text
/// ┌──────────────┬───────────────────────────────┐
/// │ targetId (1) │ PCM 16-bit mono LE (N bytes)  │
/// └──────────────┴───────────────────────────────┘
/// ```
///
/// The leading routing byte is what the ESP32 uses to forward the packet to the
/// right handset, so it is prepended by the sender and stripped by the router.
class AudioPacketModel {
  const AudioPacketModel({
    required this.targetDeviceId,
    required this.pcm,
  });

  static const int headerBytes = 1;

  final int targetDeviceId;
  final Uint8List pcm;

  int get frameBytes => pcm.length + headerBytes;

  /// Allocates exactly one buffer per frame — no copies beyond the initial
  /// `setRange`, which keeps the capture path allocation-light at 25 fps.
  Uint8List encode() {
    final packet = Uint8List(frameBytes);
    packet[0] = targetDeviceId & 0xFF;
    packet.setRange(headerBytes, packet.length, pcm);
    return packet;
  }

  static int decodeTargetDeviceId(Uint8List packet) =>
      packet.isEmpty ? -1 : packet[0];

  /// Returns a *view* over the payload (no copy) or `null` when malformed.
  static Uint8List? decodePcm(Uint8List packet) {
    if (packet.length <= headerBytes) {
      return null;
    }
    final payload = Uint8List.sublistView(packet, headerBytes);
    // 16-bit samples must be whole; a trailing odd byte means a torn frame.
    if (payload.length.isOdd) {
      return Uint8List.sublistView(payload, 0, payload.length - 1);
    }
    return payload;
  }

  static bool isPlausibleFrame(Uint8List packet) =>
      packet.length > headerBytes &&
      (packet.length - headerBytes) <= AudioConstants.bytesPerFrame * 3;

  @override
  String toString() =>
      'AudioPacketModel(to=$targetDeviceId, bytes=${pcm.length})';
}
