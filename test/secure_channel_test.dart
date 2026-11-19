import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/identity_service.dart';
import 'package:local_file_drop/services/secure_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('加密通道可双向传输大二进制帧且内容一致', () async {
    final serverIdentity = await DeviceIdentity.generate('server');
    final clientIdentity = await DeviceIdentity.generate('client');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<void>();
    server.listen((socket) async {
      try {
        final channel = await SecureChannel.accept(
          socket,
          identity: serverIdentity,
          authorize: (hello) async => hello.deviceId == clientIdentity.id,
        );
        final message = await channel.read();
        expect(message.type, 'binary');
        await channel.sendMessage('echo', {'ok': true}, message.payload);
        await channel.close();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });

    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final channel = await SecureChannel.connect(
      socket,
      identity: clientIdentity,
      expectedDeviceId: serverIdentity.id,
      expectedPublicKey: serverIdentity.publicKey,
    );
    final payload = Uint8List.fromList(
        List<int>.generate(700000, (_) => Random.secure().nextInt(256)));
    await channel.sendMessage('binary', {'size': payload.length}, payload);
    final echo = await channel.read();
    expect(echo.type, 'echo');
    expect(echo.header['ok'], true);
    expect(echo.payload, payload);
    await channel.close();
    await done.future;
    await server.close();
  });

  test('未配对设备会被拒绝', () async {
    final serverIdentity = await DeviceIdentity.generate('server');
    final clientIdentity = await DeviceIdentity.generate('unknown');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) async {
      try {
        await SecureChannel.accept(
          socket,
          identity: serverIdentity,
          authorize: (_) async => false,
        );
      } catch (_) {
        // 预期拒绝。
      }
    });
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    expect(
      () => SecureChannel.connect(socket, identity: clientIdentity),
      throwsA(isA<SocketException>()),
    );
    await server.close();
  });
}
