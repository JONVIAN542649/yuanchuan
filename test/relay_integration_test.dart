import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/relay_service.dart';

/// 用真实 relay.py 起本地服务，验证 Dart 客户端的中继协议：
/// ROOM 直桥、LISTEN+INCOMING+BRIDGE 桥接、key 规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Process relay;
  const port = 48660;
  const host = '127.0.0.1';

  setUpAll(() async {
    final python = await _resolvePython();
    relay = await Process.start(
      python,
      ['tool/relay.py'],
      environment: {'YUANCHUAN_RELAY_PORT': '$port'},
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        final probe = await Socket.connect(host, port);
        unawaited(probe.close());
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    fail('本地中继服务未能启动');
  });

  tearDownAll(() {
    relay.kill();
  });

  test('key 规则：数据房间按设备 id、配对房间按令牌', () {
    expect(RelayService.dataKey('device-1'), 'D:device-1');
    expect(RelayService.pairingKey('123456'), 'P:123456');
    expect(RelayService.defaultRelayAddress,
        '${RelayService.defaultRelayHost}:${RelayService.defaultRelayPort}');
  });

  test('ROOM 直桥：双方字节互通', () async {
    final a = await RelayService.dial('t-direct-room', host: host, port: port);
    final b = await RelayService.dial('t-direct-room', host: host, port: port);
    final readerA = StreamIterator<List<int>>(a);
    final readerB = StreamIterator<List<int>>(b);

    a.add('ping-a'.codeUnits);
    b.add('ping-b'.codeUnits);
    await a.flush();
    await b.flush();

    expect(
      await readerB.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(String.fromCharCodes(readerB.current), contains('ping-a'));
    expect(
      await readerA.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(String.fromCharCodes(readerA.current), contains('ping-b'));

    await a.close();
    await b.close();
  });

  test('LISTEN + INCOMING + BRIDGE：监听端按通知开桥', () async {
    final listener = await Socket.connect(host, port);
    listener.add('LISTEN t-listen-room\n'.codeUnits);
    await listener.flush();
    final listenerReader = StreamIterator<List<int>>(listener);

    final dialer =
        await RelayService.dial('t-listen-room', host: host, port: port);
    final dialerReader = StreamIterator<List<int>>(dialer);

    expect(
      await listenerReader.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(
      String.fromCharCodes(listenerReader.current).trim(),
      'INCOMING t-listen-room',
    );

    final bridge = await Socket.connect(host, port);
    bridge.add('BRIDGE t-listen-room\n'.codeUnits);
    await bridge.flush();
    final bridgeReader = StreamIterator<List<int>>(bridge);

    dialer.add('dialer-payload'.codeUnits);
    await dialer.flush();
    expect(
      await bridgeReader.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(
        String.fromCharCodes(bridgeReader.current), contains('dialer-payload'));

    bridge.add('bridge-response'.codeUnits);
    await bridge.flush();
    expect(
      await dialerReader.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(String.fromCharCodes(dialerReader.current),
        contains('bridge-response'));

    await listener.close();
    await dialer.close();
    await bridge.close();
  });
}

Future<String> _resolvePython() async {
  for (final candidate in const ['python3', 'python']) {
    try {
      final result = await Process.run(candidate, const ['--version']);
      if (result.exitCode == 0) return candidate;
    } catch (_) {}
  }
  fail('未找到 python3/python，无法启动 tool/relay.py');
}
