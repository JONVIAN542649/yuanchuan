import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/models/chat_models.dart';
import 'package:local_file_drop/models/transfer_models.dart';
import 'package:local_file_drop/services/auto_sync.dart';
import 'package:local_file_drop/services/chat_store.dart';
import 'package:local_file_drop/services/content_hash.dart';
import 'package:local_file_drop/services/device_store.dart';
import 'package:local_file_drop/services/identity_service.dart';
import 'package:local_file_drop/services/platform_gateway.dart';
import 'package:local_file_drop/services/transfer_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待自动同步状态超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late TransferManager sender;
  late TransferManager receiver;
  late ChatStore senderStore;
  late AutoSyncService sync;
  late DiscoveredDevice endpoint;
  late DiscoveredDevice otherPc;
  late DeviceIdentity receiverIdentity;
  var online = <DiscoveredDevice>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('yuanchuan_sync_test');
    final senderIdentity = await DeviceIdentity.generate('sync-sender');
    receiverIdentity = await DeviceIdentity.generate('sync-receiver');
    final gateway = PlatformGateway();
    receiver = TransferManager(
      identity: receiverIdentity,
      gateway: _SyncGateway(Directory(p.join(temp.path, 'receiver'))),
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
    otherPc = DiscoveredDevice(
      device: TrustedDevice(
        id: 'other-pc-id',
        name: '另一台电脑',
        publicKey: base64Encode(List.filled(32, 1)),
      ),
      host: '127.0.0.2',
      port: 9,
      lastSeen: DateTime.now(),
    );
    sender = TransferManager(
      identity: senderIdentity,
      gateway: gateway,
      deviceStore: DeviceStore(),
      endpointFor: (_) => endpoint,
      authorize: (_) async => false,
    );
    await sender.start(port: 0);
    senderStore = ChatStore(transferManager: sender);
    await senderStore.load();
    online = [];
    sync = AutoSyncService(
      chatStore: senderStore,
      gateway: gateway,
      devices: () => [endpoint, otherPc],
      onlineDevices: () => online,
      waitForStableFile: (file) async => file.lengthSync(),
    );
    await sync.load();
  });

  tearDown(() async {
    sync.stop();
    senderStore.dispose();
    await sender.close();
    await receiver.close();
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  });

  test('剪贴板：同一内容只发一次，开关关闭时不发', () async {
    online = [endpoint];
    final first = await sync.syncClipboardText('自动同步的剪贴板内容');
    expect(first, true);
    final again = await sync.syncClipboardText('自动同步的剪贴板内容');
    expect(again, false, reason: '同一内容必须去抖');
    expect(senderStore.messagesOf(receiverIdentity.id).last.source, '剪贴板');
    expect(sync.lastSentClipboardHash, contentHash('自动同步的剪贴板内容'));

    await sync.setClipboardEnabled(false);
    final third = await sync.syncClipboardText('开关关掉后的内容');
    expect(third, false);
    expect(
      senderStore.messagesOf(receiverIdentity.id).last.textContent,
      '自动同步的剪贴板内容',
    );
  });

  test('剪贴板不落盘明文', () async {
    online = [endpoint];
    await sync.syncClipboardText('秘密内容不要存偏好');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('local_file_drop.sync.last_clipboard'), isNull);
    expect(
      prefs.getString('local_file_drop.sync.last_clipboard_hash'),
      contentHash('秘密内容不要存偏好'),
    );
  });

  test('多台在线未指定目标时不发送；指定后发到该设备', () async {
    online = [endpoint, otherPc];
    final blocked = await sync.syncClipboardText('多台在线');
    expect(blocked, false);
    await sync.setPreferredTargetId(receiverIdentity.id);
    final ok = await sync.syncClipboardText('指定目标后');
    expect(ok, true);
    expect(senderStore.messagesOf(receiverIdentity.id), isNotEmpty);
  });

  test('下载图片：按开关同步且同一文件只传一次', () async {
    online = [endpoint];
    await sync.setImagesEnabled(true);
    final image = File(p.join(temp.path, 'download', 'pic.png'));
    await image.create(recursive: true);
    await image.writeAsBytes(Uint8List.fromList(List.filled(2048, 7)));
    await sync.handleNativeDownload(image.path, 2048);
    await waitUntil(() => receiver.records.isNotEmpty);
    final message = senderStore.messagesOf(receiverIdentity.id).last;
    expect(message.kind, ChatKind.image);
    expect(message.source, '下载目录');
    final countBefore = senderStore.messagesOf(receiverIdentity.id).length;
    await sync.handleNativeDownload(image.path, 2048);
    expect(senderStore.messagesOf(receiverIdentity.id).length, countBefore);
  });

  test('文件开关默认关：下载文件不入队不发送', () async {
    online = [endpoint];
    final doc = File(p.join(temp.path, 'download', 'doc.zip'));
    await doc.create(recursive: true);
    await doc.writeAsBytes(List<int>.filled(1024, 3));
    await sync.handleNativeDownload(doc.path, 1024);
    expect(senderStore.messagesOf(receiverIdentity.id), isEmpty);
  });

  test('离线积压，上线补传（断连暂停/重连补传语义）', () async {
    final image = File(p.join(temp.path, 'download', 'later.jpg'));
    await image.create(recursive: true);
    await image.writeAsBytes(Uint8List.fromList(List.filled(4096, 9)));
    await sync.handleNativeDownload(image.path, 4096);
    expect(senderStore.messagesOf(receiverIdentity.id), isEmpty);
    online = [endpoint];
    await sync.flushBacklog();
    await waitUntil(() => receiver.records.isNotEmpty);
    expect(senderStore.messagesOf(receiverIdentity.id).last.source, '下载目录');
    await sync.flushBacklog();
  });
}

class _SyncGateway extends PlatformGateway {
  _SyncGateway(this.root);
  final Directory root;

  @override
  Future<Directory> receiveDirectory() async {
    final dir = Directory(p.join(root.path, 'receiver'));
    await dir.create(recursive: true);
    await Directory(p.join(dir.path, '.incoming')).create(recursive: true);
    return dir;
  }
}
