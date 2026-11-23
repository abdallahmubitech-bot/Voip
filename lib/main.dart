import 'package:flutter/material.dart';

import 'app.dart';
import 'core/di/injector.dart';

/// Override at build time:
/// `flutter run --dart-define=VOIP_SERVER_URL=ws://192.168.4.1:81`
const String _serverUrlOverride = String.fromEnvironment('VOIP_SERVER_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies(
    serverUrl: _serverUrlOverride.isEmpty ? null : _serverUrlOverride,
  );
  runApp(const Esp32VoipApp());
}
