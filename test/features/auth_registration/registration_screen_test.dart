import 'package:esp32_voip/core/network/connection_status.dart';
import 'package:esp32_voip/core/network/websocket_config.dart';
import 'package:esp32_voip/core/utils/result.dart';
import 'package:esp32_voip/features/auth_registration/domain/entities/device_identity.dart';
import 'package:esp32_voip/features/auth_registration/domain/repositories/registration_repository.dart';
import 'package:esp32_voip/features/auth_registration/domain/usecases/register_device_usecase.dart';
import 'package:esp32_voip/features/auth_registration/presentation/controllers/registration_controller.dart';
import 'package:esp32_voip/features/auth_registration/presentation/controllers/registration_state.dart';
import 'package:esp32_voip/features/auth_registration/presentation/screens/registration_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeRegistrationRepository repository;
  late RegistrationController controller;

  setUp(() {
    repository = FakeRegistrationRepository();
    controller = RegistrationController(
      registerDevice: RegisterDeviceUseCase(repository),
      repository: repository,
    );
  });

  tearDown(() async {
    await controller.close();
    await repository.disconnect();
  });

  Widget harness() => RepositoryProvider<WebSocketConfig>.value(
        value: WebSocketConfig.fromUrl('ws://192.168.4.1:81'),
        child: BlocProvider<RegistrationController>.value(
          value: controller,
          child: const MaterialApp(home: RegistrationScreen()),
        ),
      );

  testWidgets('renders the join form and the router hint', (tester) async {
    await tester.pumpWidget(harness());

    expect(find.text('Join the local call network'), findsOneWidget);
    expect(find.text('Join network'), findsOneWidget);
    expect(find.textContaining('ws://192.168.4.1:81'), findsOneWidget);
    expect(controller.state, isA<RegistrationIdle>());
  });

  testWidgets('rejects a too-short username before hitting the network',
      (tester) async {
    await tester.pumpWidget(harness());

    await tester.enterText(find.byType(TextFormField), 'ab');
    await tester.tap(find.text('Join network'));
    await tester.pump();

    expect(find.text('Use at least 3 characters.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('registers and exposes the assigned routing id', (tester) async {
    await tester.pumpWidget(harness());

    await tester.enterText(find.byType(TextFormField), 'User_A');
    await tester.tap(find.text('Join network'));
    await tester.pump(); // RegistrationSubmitting
    // The controller awaits the repository off the fake-async clock, so let the
    // real microtask queue drain before asserting.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(repository.registerCallCount, 1);
    final state = controller.state;
    expect(state, isA<RegistrationSuccess>());
    expect((state as RegistrationSuccess).identity.username, 'User_A');
    expect(state.identity.deviceId, 3);
  });
}

class FakeRegistrationRepository implements RegistrationRepository {
  int registerCallCount = 0;

  @override
  DeviceIdentity? cachedIdentity;

  @override
  Stream<DeviceIdentity> get identityStream =>
      const Stream<DeviceIdentity>.empty();

  @override
  Stream<WebSocketStatus> get connectionStatus =>
      const Stream<WebSocketStatus>.empty();

  @override
  Future<Result<DeviceIdentity>> register({required String username}) async {
    registerCallCount++;
    final identity = DeviceIdentity(
      username: username,
      deviceId: 3,
      registeredAt: DateTime(2026),
    );
    cachedIdentity = identity;
    return Ok<DeviceIdentity>(identity);
  }

  @override
  Future<Result<DeviceIdentity>> refreshRegistration() =>
      register(username: cachedIdentity?.username ?? 'User_A');

  @override
  Future<void> disconnect() async {}
}
