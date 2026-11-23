import 'dart:typed_data';

import 'package:esp32_voip/core/utils/constants.dart';
import 'package:esp32_voip/features/voice_call/data/models/audio_packet_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioPacketModel', () {
    test('prepends the target routing byte and round-trips the PCM payload', () {
      final pcm = Uint8List.fromList(
        List<int>.generate(AudioConstants.bytesPerFrame, (i) => i % 256),
      );
      final packet = AudioPacketModel(targetDeviceId: 7, pcm: pcm).encode();

      expect(packet.length, pcm.length + AudioPacketModel.headerBytes);
      expect(packet.first, 7);
      expect(AudioPacketModel.decodeTargetDeviceId(packet), 7);

      final decoded = AudioPacketModel.decodePcm(packet);
      expect(decoded, isNotNull);
      expect(decoded!.length, pcm.length);
      expect(decoded, orderedEquals(pcm));
    });

    test('masks ids above one byte', () {
      final packet =
          AudioPacketModel(targetDeviceId: 0x1FF, pcm: Uint8List(4)).encode();
      expect(packet.first, 0xFF);
    });

    test('rejects header-only frames', () {
      final packet = Uint8List.fromList(<int>[3]);
      expect(AudioPacketModel.decodePcm(packet), isNull);
      expect(AudioPacketModel.isPlausibleFrame(packet), isFalse);
    });

    test('trims a torn odd byte from the payload', () {
      final packet = Uint8List.fromList(<int>[3, 1, 2, 3]);
      final pcm = AudioPacketModel.decodePcm(packet);
      expect(pcm, isNotNull);
      expect(pcm!.length, 2);
    });
  });
}
