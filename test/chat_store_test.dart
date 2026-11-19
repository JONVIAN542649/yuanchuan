import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/models/chat_models.dart';
import 'package:local_file_drop/models/transfer_models.dart';
import 'package:local_file_drop/services/chat_store.dart';
import 'package:local_file_drop/services/device_store.dart';
import 'package:local_file_drop/services/identity_service.dart';
import 'package:local_file_drop/services/platform_gateway.dart';
import 'package:local_file_drop/services/transfer_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待聊天状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late DeviceIdentity senderIdentity;
  late DeviceIdentity receiverIdentity;
  late TransferManager sender;
  late TransferManager receiver;
  late ChatStore senderStore;
  late ChatStore receiverStore;
  late DiscoveredDevice endpoint;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('local_file_drop_chat_test');
    senderIdentity = await DeviceIdentity.generate('chat-sender');
    receiverIdentity = await DeviceIdentity.generate('chat-receiver');
    final senderGateway = _ChatGateway(Directory(p.join(temp.path, 'sender')));
    final receiverGateway =
        _ChatGateway(Directory(p.join(temp.path, 'receiver')));
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
    endpoint = DiscoveredDevice(
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
    senderStore = ChatStore(transferManager: sender);
    await senderStore.load();
    receiverStore = ChatStore(transferManager: receiver);
    await receiverStore.load();
  });

  tearDown(() async {
    senderStore.dispose();
    receiverStore.dispose();
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

  test('文字聊天两端消息对齐并自动标记状态', () async {
    await senderStore.sendText(endpoint, '你好，原传聊天！');
    await waitUntil(() =>
        senderStore.messagesOf(receiverIdentity.id).last.status ==
        ChatStatus.sent);
    await waitUntil(() =>
        receiverStore.messagesOf(senderIdentity.id).last.status ==
        ChatStatus.received);
    final received =
        receiverStore.messagesOf(senderIdentity.id).last;
    expect(received.kind, ChatKind.text);
    expect(received.textContent, '你好，原传聊天！');
    // 两端消息 id / 传输 id 一致（同一传输在两端的锚点）。
    expect(received.id, senderStore.messagesOf(receiverIdentity.id).last.id);
    expect(received.transferId, received.id);
  });

  test('接收文件自动生成消息并带保存路径（免确认）', () async {
    final source = File(p.join(temp.path, 'chat-doc.bin'));
    await source.writeAsBytes(List<int>.generate(777, (i) => i % 256));
    final item = TransferItem(
      id: randomId(),
      name: 'chat-doc.bin',
      relativePath: 'chat-doc.bin',
      size: await source.length(),
      path: source.path,
    );
    await senderStore.sendFiles(endpoint, [item]);
    await waitUntil(() =>
        receiverStore.messagesOf(senderIdentity.id).isNotEmpty &&
        receiverStore.messagesOf(senderIdentity.id).last.status ==
            ChatStatus.received);
    final received = receiverStore.messagesOf(senderIdentity.id).last;
    expect(received.kind, ChatKind.file);
    expect(received.fileName, 'chat-doc.bin');
    expect(received.filePath, isNotNull);
    expect(await File(received.filePath!).readAsBytes(),
        await source.readAsBytes());
  });

  test('聊天记录本地持久化，重开应用不丢', () async {
    await senderStore.sendText(endpoint, '持久化测试');
    await waitUntil(() =>
        senderStore.messagesOf(receiverIdentity.id).last.status ==
        ChatStatus.sent);
    await waitUntil(() =>
        receiverStore.messagesOf(senderIdentity.id).last.status ==
        ChatStatus.received);
    // 等 600ms 落盘定时器
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final reloaded = ChatStore(transferManager: receiver);
    await reloaded.load();
    final messages = reloaded.messagesOf(senderIdentity.id);
    expect(messages, isNotEmpty);
    expect(messages.last.textContent, '持久化测试');
    expect(messages.last.status, ChatStatus.received);
    reloaded.dispose();
  });

  test('图片按扩展名识别为图片气泡', () {
    expect(chatKindIsImage('IMG_2026.jpg'), isTrue);
    expect(chatKindIsImage('photo.PNG'), isTrue);
    expect(chatKindIsImage('report.pdf'), isFalse);
    expect(chatKindIsImage('archive.zip'), isFalse);
  });
}

/// 接收目录落在临时目录。
class _ChatGateway extends PlatformGateway {
  _ChatGateway(this.root);
  final Directory root;

  @override
  Future<Directory> receiveDirectory() async {
    final dir = Directory(p.join(root.path, 'receiver'));
    await dir.create(recursive: true);
    await Directory(p.join(dir.path, '.incoming')).create(recursive: true);
    return dir;
  }
}
