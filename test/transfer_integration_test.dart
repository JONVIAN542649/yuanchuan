import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/models/transfer_models.dart';
import 'package:local_file_drop/services/device_store.dart';
import 'package:local_file_drop/services/identity_service.dart';
import 'package:local_file_drop/services/platform_gateway.dart';
import 'package:local_file_drop/services/transfer_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class TestGateway extends PlatformGateway {
  TestGateway(this.root, {this.readDelay = Duration.zero});
  final Directory root;
  final Duration readDelay;

  @override
  Future<Uint8List> readChunk(TransferItem item, int offset, int length) async {
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return super.readChunk(item, offset, length);
  }

  @override
  Future<Directory> receiveDirectory() async {
    await root.create(recursive: true);
    await Directory(p.join(root.path, '.incoming')).create(recursive: true);
    return root;
  }
}

class WrongHashGateway extends TestGateway {
  WrongHashGateway(super.root);
  @override
  Future<({String hash, int size})> hashItem(TransferItem item) async =>
      (hash: List.filled(64, '0').join(), size: item.size);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late DeviceIdentity senderIdentity;
  late DeviceIdentity receiverIdentity;
  late TransferManager sender;
  late TransferManager receiver;
  late TestGateway senderGateway;
  late TestGateway receiverGateway;
  late DiscoveredDevice endpoint;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp =
        await Directory.systemTemp.createTemp('local_file_drop_transfer_test');
    senderIdentity = await DeviceIdentity.generate('sender');
    receiverIdentity = await DeviceIdentity.generate('receiver');
    senderGateway = TestGateway(Directory(p.join(temp.path, 'sender')));
    receiverGateway = TestGateway(Directory(p.join(temp.path, 'receiver')));
    final senderStore = DeviceStore();
    final receiverStore = DeviceStore();
    final trustedReceiver = TrustedDevice(
      id: receiverIdentity.id,
      name: receiverIdentity.name,
      publicKey: receiverIdentity.publicKeyBase64,
    );
    endpoint = DiscoveredDevice(
      device: trustedReceiver,
      host: InternetAddress.loopbackIPv4.address,
      port: 0,
      lastSeen: DateTime.now(),
    );
    receiver = TransferManager(
      identity: receiverIdentity,
      gateway: receiverGateway,
      deviceStore: receiverStore,
      endpointFor: (_) => null,
      authorize: (hello) async =>
          hello.deviceId == senderIdentity.id &&
          base64Encode(hello.publicKey) == senderIdentity.publicKeyBase64,
    );
    await receiver.start(port: 0);
    endpoint = DiscoveredDevice(
      device: trustedReceiver,
      host: endpoint.host,
      port: receiver.serverPort!,
      lastSeen: DateTime.now(),
    );
    sender = TransferManager(
      identity: senderIdentity,
      gateway: senderGateway,
      deviceStore: senderStore,
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
    );
    await sender.start(port: 0);
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

  Future<TransferItem> makeFile(String name, int size) async {
    final source = File(p.join(temp.path, name));
    final bytes = Uint8List(size);
    final random = Random.secure();
    for (var index = 0; index < size; index++) {
      bytes[index] = random.nextInt(256);
    }
    await source.writeAsBytes(bytes, flush: true);
    return TransferItem(
      id: randomId(),
      name: name,
      relativePath: name,
      size: size,
      path: source.path,
    );
  }

  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        final senderState = sender.records
            .map((r) => '${r.status}/${r.error}/${r.bytesTransferred}')
            .join(',');
        final receiverState = receiver.records
            .map((r) => '${r.status}/${r.error}/${r.bytesTransferred}')
            .join(',');
        fail('等待传输状态超时；sender=$senderState；receiver=$receiverState');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> useSlowSender() async {
    await sender.close();
    senderGateway = TestGateway(senderGateway.root,
        readDelay: const Duration(milliseconds: 80));
    sender = TransferManager(
      identity: senderIdentity,
      gateway: senderGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
    );
    await sender.start(port: 0);
  }

  test('任意二进制文件通过真实 socket 原样传输并通过 SHA-256', () async {
    final item = await makeFile('original.bin', 3 * 1024 * 1024 + 117);
    await sender.sendItems([item], endpoint);
    final received = File(p.join(receiverGateway.root.path, item.name));
    expect(await received.exists(), true);
    expect(sha256.convert(await received.readAsBytes()),
        sha256.convert(await File(item.path!).readAsBytes()));
    expect(sender.records.single.status, TransferStatus.completed);
    expect(receiver.records.single.status, TransferStatus.completed);
  });

  test('多文件队列和较大二进制文件按顺序原样完成', () async {
    final items = <TransferItem>[
      await makeFile('queue-large.bin', 12 * 1024 * 1024 + 33),
      await makeFile('queue-empty.bin', 0),
      await makeFile('queue-last.bin', 1024 * 1024 + 7),
    ];
    await sender
        .sendItems(items, endpoint)
        .timeout(const Duration(seconds: 60));
    expect(sender.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
    expect(receiver.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
    for (final item in items) {
      final received =
          File(p.join(receiverGateway.root.path, item.relativePath));
      expect(await received.length(), item.size);
      expect(sha256.convert(await received.readAsBytes()),
          sha256.convert(await File(item.path!).readAsBytes()));
    }
  });

  test('不限长文字通过加密分块原样传输，接收端不落文件', () async {
    final text = List.generate(
      60000,
      (index) => '第 $index 行 · 原传文字传输，无固定长度上限。',
    ).join('\n');
    await sender.sendText(text, endpoint).timeout(const Duration(seconds: 40));
    final sent = sender.records.single;
    final received = receiver.records.single;
    expect(sent.status, TransferStatus.completed);
    expect(sent.isTextRecord, true);
    expect(received.status, TransferStatus.completed);
    expect(received.isTextRecord, true);
    expect(received.textContent, text);
    expect(received.savePath, null);
    final leftovers =
        await Directory(p.join(receiverGateway.root.path, '.incoming'))
            .list()
            .where((entity) => p.basename(entity.path).startsWith(received.id))
            .toList();
    expect(leftovers, isEmpty);
  });

  test('接收端已有部分临时文件时只续传剩余内容', () async {
    final item = await makeFile('resume.bin', 2 * 1024 * 1024 + 19);
    final sourceBytes = await File(item.path!).readAsBytes();
    final expectedHash = sha256.convert(sourceBytes).toString();
    final incoming = Directory(p.join(receiverGateway.root.path, '.incoming'));
    await incoming.create(recursive: true);
    final half = sourceBytes.length ~/ 2;
    await File(p.join(incoming.path, '${item.id}.part'))
        .writeAsBytes(sourceBytes.sublist(0, half));
    await File(p.join(incoming.path, '${item.id}.json'))
        .writeAsString(jsonEncode({
      'name': item.name,
      'relativePath': item.relativePath,
      'size': item.size,
      'sha256': expectedHash,
    }));
    await sender.sendItems([item], endpoint);
    final received = File(p.join(receiverGateway.root.path, item.name));
    expect(await received.readAsBytes(), sourceBytes);
  });

  test('同名文件不会覆盖，零字节文件也能完成', () async {
    final first = await makeFile('same.bin', 128);
    await sender.sendItems([first], endpoint);
    final secondSource = File(p.join(temp.path, 'second-source.bin'));
    await secondSource.writeAsBytes(List<int>.filled(128, 7));
    final second = TransferItem(
      id: randomId(),
      name: 'same.bin',
      relativePath: 'same.bin',
      size: 128,
      path: secondSource.path,
    );
    await sender.sendItems([second], endpoint);
    final empty = await makeFile('empty.bin', 0);
    await sender.sendItems([empty], endpoint);
    expect(
        await File(p.join(receiverGateway.root.path, 'same.bin')).readAsBytes(),
        await File(first.path!).readAsBytes());
    expect(
        await File(p.join(receiverGateway.root.path, 'same (1).bin'))
            .readAsBytes(),
        await secondSource.readAsBytes());
    expect(
        await File(p.join(receiverGateway.root.path, 'empty.bin')).length(), 0);
  });

  test('文件夹相对路径和中文文件名保持正确', () async {
    final source =
        File(p.join(temp.path, 'source', '旅行 相册', '子目录', '原始 文件.bin'));
    await source.create(recursive: true);
    await source.writeAsBytes(List<int>.generate(8193, (index) => index % 251));
    final item = TransferItem(
      id: randomId(),
      name: '原始 文件.bin',
      relativePath: '旅行 相册/子目录/原始 文件.bin',
      size: await source.length(),
      path: source.path,
    );
    await sender
        .sendItems([item], endpoint).timeout(const Duration(seconds: 20));
    final received =
        File(p.join(receiverGateway.root.path, '旅行 相册', '子目录', '原始 文件.bin'));
    expect(await received.exists(), true);
    expect(sha256.convert(await received.readAsBytes()),
        sha256.convert(await source.readAsBytes()));
  });

  test('接收端暂停后，发送端继续可从断点完成', () async {
    await useSlowSender();
    final item = await makeFile('remote-pause.bin', 4 * 1024 * 1024);
    final sending = sender.sendItems([item], endpoint);
    await waitUntil(() =>
        receiver.records.isNotEmpty &&
        receiver.records.single.bytesTransferred > 0 &&
        receiver.records.single.bytesTransferred < item.size);
    await receiver.pause(item.id);
    await sending.timeout(const Duration(seconds: 15));
    expect(sender.records.single.status, TransferStatus.paused);
    expect(receiver.records.single.status, TransferStatus.paused);
    final pausedBytes = receiver.records.single.bytesTransferred;
    expect(pausedBytes, greaterThan(0));
    expect(pausedBytes, lessThan(item.size));
    await sender.resume(item.id);
    await waitUntil(() =>
        sender.records.single.status == TransferStatus.completed &&
        receiver.records.single.status == TransferStatus.completed);
    final received = File(p.join(receiverGateway.root.path, item.name));
    expect(sha256.convert(await received.readAsBytes()),
        sha256.convert(await File(item.path!).readAsBytes()));
  });

  test('发送端取消后两端状态一致，且不生成完成文件', () async {
    await useSlowSender();
    final item = await makeFile('cancel.bin', 4 * 1024 * 1024);
    final sending = sender.sendItems([item], endpoint);
    await waitUntil(() =>
        sender.records.isNotEmpty &&
        sender.records.single.bytesTransferred > 0);
    await sender.cancel(item.id);
    await sending.timeout(const Duration(seconds: 15));
    await waitUntil(() =>
        receiver.records.isNotEmpty &&
        receiver.records.single.status == TransferStatus.cancelled);
    expect(sender.records.single.status, TransferStatus.cancelled);
    expect(await File(p.join(receiverGateway.root.path, item.name)).exists(),
        false);
    // 取消后不能留下 .part 或元数据残片
    //（finally 的删除与状态可见有先后，用轮询收敛避免偶发）。
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var leftovers = <FileSystemEntity>[];
    while (true) {
      leftovers = await Directory(p.join(receiverGateway.root.path, '.incoming'))
          .list()
          .where((entity) => p.basename(entity.path).startsWith(item.id))
          .toList();
      if (leftovers.isEmpty) break;
      if (DateTime.now().isAfter(deadline)) fail('取消后的残留文件未清理');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });

  test('连接暂时失败会自动重试，原文件仍保持一致', () async {
    final item = await makeFile('retry.bin', 1024 * 1024);
    final validEndpoint = endpoint;
    endpoint = DiscoveredDevice(
      device: validEndpoint.device,
      host: validEndpoint.host,
      port: 1,
      lastSeen: DateTime.now(),
    );
    final sending = sender.sendItems([item], endpoint);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    endpoint = validEndpoint;
    await sending.timeout(const Duration(seconds: 20));
    expect(sender.records.single.status, TransferStatus.completed);
    final received = File(p.join(receiverGateway.root.path, item.name));
    expect(sha256.convert(await received.readAsBytes()),
        sha256.convert(await File(item.path!).readAsBytes()));
  });

  test('源文件尺寸报小时按真实字节数发送，文件不缩水', () async {
    final real = await makeFile('underreported.bin', 3 * 1024 * 1024 + 57);
    // 模拟 file_picker / ContentProvider 把 size 报成一半。
    final item = TransferItem(
      id: real.id,
      name: real.name,
      relativePath: real.relativePath,
      size: real.size ~/ 2,
      path: real.path,
      uri: real.uri,
    );
    await sender.sendItems([item], endpoint);
    final received = File(p.join(receiverGateway.root.path, item.name));
    expect(await received.length(), real.size);
    expect(sha256.convert(await received.readAsBytes()),
        sha256.convert(await File(real.path!).readAsBytes()));
    expect(sender.records.single.status, TransferStatus.completed);
    expect(receiver.records.single.status, TransferStatus.completed);
  });

  test('哈希不一致时不能生成完成文件', () async {
    final item = await makeFile('bad.bin', 1024);
    await sender.close();
    sender = TransferManager(
      identity: senderIdentity,
      gateway: WrongHashGateway(senderGateway.root),
      deviceStore: DeviceStore(),
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
    );
    await sender.start(port: 0);
    await sender.sendItems([item], endpoint);
    expect(sender.records.single.status, TransferStatus.failed);
    expect(await File(p.join(receiverGateway.root.path, 'bad.bin')).exists(),
        false);
    expect(receiver.records.single.status, TransferStatus.failed);
  });

  test('批量文件共用一条加密连接，第二批重新建连', () async {
    var opened = 0;
    await sender.close();
    sender = TransferManager(
      identity: senderIdentity,
      gateway: senderGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
      onSenderChannelOpened: () => opened++,
    );
    await sender.start(port: 0);
    final items = [
      await makeFile('batch-1.bin', 700 * 1024),
      await makeFile('batch-2.bin', 0),
      await makeFile('batch-3.bin', 1500 * 1024 + 11),
    ];
    await sender
        .sendItems(items, endpoint)
        .timeout(const Duration(seconds: 40));
    expect(opened, 1, reason: '同一批文件必须复用一条连接');
    expect(sender.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
    expect(receiver.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
    for (final item in items) {
      final received =
          File(p.join(receiverGateway.root.path, item.relativePath));
      expect(
          await received.readAsBytes(), await File(item.path!).readAsBytes());
    }
    // 新一批发送重新建连；上一条连接已随批次结束正常关闭。
    final second = await makeFile('batch-4.bin', 256 * 1024 + 5);
    await sender
        .sendItems([second], endpoint).timeout(const Duration(seconds: 20));
    expect(opened, 2);
    expect(
        await File(p.join(receiverGateway.root.path, 'batch-4.bin')).exists(),
        true);
  });

  test('接收前询问：拒绝后发送端失败、本批剩余取消', () async {
    var asked = 0;
    await receiver.close();
    receiver = TransferManager(
      identity: receiverIdentity,
      gateway: receiverGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => null,
      authorize: (hello) async =>
          hello.deviceId == senderIdentity.id &&
          base64Encode(hello.publicKey) == senderIdentity.publicKeyBase64,
      authorizeOffer: (offer) async {
        asked++;
        return false;
      },
    );
    await receiver.start(port: 0);
    endpoint = DiscoveredDevice(
      device: endpoint.device,
      host: endpoint.host,
      port: receiver.serverPort!,
      lastSeen: DateTime.now(),
    );
    final items = [
      await makeFile('deny-1.bin', 64 * 1024),
      await makeFile('deny-2.bin', 32 * 1024),
    ];
    await sender
        .sendItems(items, endpoint)
        .timeout(const Duration(seconds: 30));
    expect(asked, 1);
    expect(
      sender.records.firstWhere((record) => record.id == items[0].id).status,
      TransferStatus.failed,
    );
    expect(
      sender.records.firstWhere((record) => record.id == items[1].id).status,
      TransferStatus.cancelled,
    );
    expect(receiver.records.single.status, TransferStatus.cancelled);
    expect(
      await File(p.join(receiverGateway.root.path, 'deny-1.bin')).exists(),
      false,
    );
  });

  test('接收前询问：同意后 60 秒会话内同批只询问一次', () async {
    var asked = 0;
    await receiver.close();
    receiver = TransferManager(
      identity: receiverIdentity,
      gateway: receiverGateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => null,
      authorize: (hello) async =>
          hello.deviceId == senderIdentity.id &&
          base64Encode(hello.publicKey) == senderIdentity.publicKeyBase64,
      authorizeOffer: (offer) async {
        asked++;
        return true;
      },
    );
    await receiver.start(port: 0);
    endpoint = DiscoveredDevice(
      device: endpoint.device,
      host: endpoint.host,
      port: receiver.serverPort!,
      lastSeen: DateTime.now(),
    );
    final items = [
      await makeFile('ask-1.bin', 48 * 1024),
      await makeFile('ask-2.bin', 96 * 1024),
      await makeFile('ask-3.bin', 24 * 1024),
    ];
    await sender
        .sendItems(items, endpoint)
        .timeout(const Duration(seconds: 30));
    expect(asked, 1, reason: '同一会话批量文件只弹一次确认');
    expect(sender.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
    expect(receiver.records.map((record) => record.status),
        everyElement(TransferStatus.completed));
  });
}
