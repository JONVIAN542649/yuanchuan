import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/models/transfer_models.dart';
import 'package:local_file_drop/services/device_store.dart';
import 'package:local_file_drop/services/identity_service.dart';
import 'package:local_file_drop/services/platform_gateway.dart';
import 'package:path/path.dart' as p;
import 'package:local_file_drop/services/transfer_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 接收目录落在本临时目录，不污染真实 Downloads。
class _BenchGateway extends PlatformGateway {
  _BenchGateway(this.root);
  final Directory root;

  @override
  Future<Directory> receiveDirectory() async {
    final dir = Directory(p.join(root.path, 'receiver'));
    await dir.create(recursive: true);
    await Directory(p.join(dir.path, '.incoming')).create(recursive: true);
    return dir;
  }
}

/// 回环吞吐基准：手机→PC 链路的本机上限参考。
/// 输出 MB/s 供修前/修后对比；不是断言型测试，慢了只会打日志。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late TransferManager sender;
  late TransferManager receiver;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('yuanchuan_bench');
  });

  tearDown(() async {
    await sender.close();
    await receiver.close();
    // Windows 下新文件可能被杀软短暂持句柄，删除带重试。
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  });

  test('回环吞吐基准（64MiB 单文件）', () async {
    final size = 64 * 1024 * 1024;
    final source = File(p.join(temp.path, 'bench.bin'));
    final random = Random.secure();
    final sink = source.openWrite();
    final chunk = Uint8List(1024 * 1024);
    var written = 0;
    while (written < size) {
      final n = min(chunk.length, size - written);
      for (var i = 0; i < n; i++) {
        chunk[i] = random.nextInt(256);
      }
      sink.add(Uint8List.sublistView(chunk, 0, n));
      written += n;
    }
    await sink.close();
    expect(await source.length(), size);

    final senderIdentity = await DeviceIdentity.generate('bench-sender');
    final receiverIdentity = await DeviceIdentity.generate('bench-receiver');
    final senderGateway = PlatformGateway();
    final receiverGateway = _BenchGateway(temp);
    receiver = TransferManager(
      identity: receiverIdentity,
      gateway: receiverGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => null,
      authorize: (hello) async =>
          hello.deviceId == senderIdentity.id &&
          base64Encode(hello.publicKey) == senderIdentity.publicKeyBase64,
    );
    await receiver.start(port: 0);
    final endpoint = DiscoveredDevice(
      device: TrustedDevice(
        id: receiverIdentity.id,
        name: receiverIdentity.name,
        publicKey: receiverIdentity.publicKeyBase64,
      ),
      host: InternetAddress.loopbackIPv4.address,
      port: receiver.serverPort!,
      lastSeen: DateTime.now(),
    );
    sender = TransferManager(
      identity: senderIdentity,
      gateway: senderGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
    );
    await sender.start(port: 0);

    final item = TransferItem(
      id: randomId(),
      name: 'bench.bin',
      relativePath: 'bench.bin',
      size: size,
      path: source.path,
    );
    final watch = Stopwatch()..start();
    await sender.sendItems([item], endpoint).timeout(const Duration(minutes: 5));
    watch.stop();
    final mbps = size / watch.elapsedMicroseconds / 1.048576; // MB/s
    // ignore: avoid_print
    print('回环吞吐：${mbps.toStringAsFixed(1)} MB/s（64MiB，耗时 ${watch.elapsedMilliseconds}ms）');
    expect(sender.records.single.status, TransferStatus.completed);
    expect(
      await File(p.join(temp.path, 'receiver', 'bench.bin')).length(),
      size,
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
}
