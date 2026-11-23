import 'dart:convert';

import 'package:esp32_voip/features/voice_call/data/models/call_signal_model.dart';
import 'package:esp32_voip/features/voice_call/domain/entities/call_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallSignalModel', () {
    test('parses the line_busy frame from the firmware', () {
      final model = CallSignalModel.fromRawFrame(
        jsonEncode(<String, Object?>{
          'type': 'line_busy',
          'message': 'Please wait, the user is on another call.',
        }),
      );

      expect(model.type, CallSignalType.lineBusy);
      expect(model.isTerminal, isTrue);
      expect(model.message, 'Please wait, the user is on another call.');
    });

    test('parses make-call acknowledgements with a peer id', () {
      final model = CallSignalModel.fromRawFrame(
        jsonEncode(<String, Object?>{
          'type': 'call_answered',
          'from': 'User_B',
          'id': '5',
        }),
      );

      expect(model.type, CallSignalType.callAnswered);
      expect(model.from, 'User_B');
      expect(model.deviceId, 5);
    });

    test('unknown types degrade instead of throwing', () {
      final model = CallSignalModel.fromRawFrame(
        jsonEncode(<String, Object?>{'type': 'firmware_v9_feature'}),
      );
      expect(model.type, CallSignalType.unknown);
    });

    test('rejects non-JSON frames', () {
      expect(
        () => CallSignalModel.fromRawFrame('<html>nope</html>'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
