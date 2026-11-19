import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/transfer_models.dart';
import 'connection_path.dart';
import 'crypto_pool.dart';
import 'device_store.dart';
import 'discovery_service.dart';
import 'identity_service.dart';
import 'platform_gateway.dart';
import 'safe_path.dart';
import 'secure_channel.dart';
import 'speed_monitor.dart';
import 'transfer_history_store.dart';

/// 流水线窗口深度：发送端最多同时在途的分块数，接收端仍逐块回执。
/// 对端为旧版本时通过 offer/accept 协商自动退回逐块确认（深度 1）。
const sendWindowDepth = 8;

/// 发送端并行加密块数（isolate 池并行度）与接收端解密预读深度。
const cryptoDepth = 4;
const decryptDepth = 3;

/// 连接失败重试的退避序列（秒）；连续失败超过 [maxConnectAttempts] 次后
/// 停止自动重试，设备恢复后可点“继续”。
const _retryBackoffSeconds = [2, 3, 5, 8, 15];
const maxConnectAttempts = 8;

enum _SendOutcome {
  /// 接收端校验通过，连接流上干净，可直接接力下一个文件。
  completed,

  /// 哈希不一致被拒收；连接流上同样干净，可接力下一个文件。
  verifyFailed,

  /// 接收端请求暂停；本端关闭连接，后续文件重新建连。
  remotePaused,

  /// 接收端请求取消；本端关闭连接，后续文件重新建连。
  remoteCancelled,

  /// 连接中断；接收端已保留断点，重连后继续。
  connectionLost,
}

/// 接收端明确拒绝（接收前询问被点了“拒绝”）。
class _PeerRefusedException implements Exception {
  const _PeerRefusedException(this.message);
  final String message;

  @override
  String toString() => message;
}

class TransferManager extends ChangeNotifier {
  TransferManager({
    required this.identity,
    required this.gateway,
    required this.deviceStore,
    required this.endpointFor,
    required this.authorize,
    this.onBackgroundMessage,
    this.relayDial,
    this.onSenderChannelOpened,
    this.authorizeOffer,
    TransferHistoryStore? historyStore,
  }) : historyStore = historyStore ?? TransferHistoryStore();

  final DeviceIdentity identity;
  final PlatformGateway gateway;
  final DeviceStore deviceStore;
  final DiscoveredDevice? Function(String deviceId) endpointFor;
  final Future<bool> Function(HelloMessage hello) authorize;
  final void Function(String message)? onBackgroundMessage;

  /// 跨网回落：按对端设备 id 经中继拨号；null 表示不启用中继。
  final Future<Socket?> Function(String peerId)? relayDial;

  /// 测试钩子：发送端每建立一条新的加密连接时回调一次。
  final void Function()? onSenderChannelOpened;

  /// 接收前询问（Quick Share 精华）：每个新会话的首个 offer 回调一次，
  /// 返回 false 时对端收到 refused 并停止本批；60 秒内同设备免重复询问。
  final Future<bool> Function(IncomingOffer offer)? authorizeOffer;

  /// 可注入的历史存储（测试可指向临时目录）。
  final TransferHistoryStore historyStore;

  final List<TransferRecord> _records = [];
  final Map<String, _TransferControl> _controls = {};
  final Set<String> _activeReceiving = {};
  final Set<String> _activeDestinations = {};
  final Map<String, TransferThroughput> _throughput = {};
  // 接收确认的会话记忆：同一设备 60 秒内免重复询问/拒绝。
  final Map<String, DateTime> _consentCache = {};
  final Map<String, DateTime> _denyCache = {};
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  ServerSocket? _server;
  bool _loading = false;

  /// 按目标设备记忆最近成功的直连/中继路径，供竞速优先。
  final Map<String, ConnectionPathMemory> _pathMemory = {};

  List<TransferRecord> get records => List.unmodifiable(_records);
  int? get serverPort => _server?.port;

  /// 该传输当前瞬时速率（字节/秒）；样本不足或无增长时为 null。
  int? speedOf(String id) => _throughput[id]?.bytesPerSecond();

  /// 正在传输的任务数与总速率（SHAREit/Feem 式的整批速度感）。
  int get activeTransferring => _records
      .where((record) => record.status == TransferStatus.transferring)
      .length;

  int get totalSpeed {
    var total = 0;
    for (final record in _records) {
      if (record.status != TransferStatus.transferring) continue;
      total += _throughput[record.id]?.bytesPerSecond() ?? 0;
    }
    return total;
  }

  Future<void> start({int port = transferPort}) async {
    if (_server != null) return;
    await _loadHistory();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server!.listen(
      (socket) => unawaited(_handleConnection(socket)),
      onError: (Object error) => debugPrint('接收服务错误：$error'),
    );
  }

  Future<void> sendItems(
      List<TransferItem> items, DiscoveredDevice device) async {
    final queue = <String>[];
    for (final item in items) {
      final safePath = safeRelativePath(item.relativePath);
      final now = DateTime.now();
      final record = TransferRecord(
        id: item.id,
        deviceId: device.device.id,
        deviceName: device.device.name,
        name: item.name,
        relativePath: safePath,
        size: item.size,
        direction: TransferDirection.sending,
        status: TransferStatus.waiting,
        createdAt: now,
        updatedAt: now,
        item: TransferItem(
          id: item.id,
          name: item.name,
          relativePath: safePath,
          size: item.size,
          path: item.path,
          uri: item.uri,
          data: item.data,
        ),
        isText: item.isText,
      );
      _upsert(record);
      queue.add(record.id);
    }
    await _sendQueue(queue);
  }

  /// 发送任意长度文字：UTF-8 后沿用加密分块协议，不经过单条 JSON，
  /// 因此不会受消息体大小限制；接收端在内存中还原文字。
  Future<void> sendText(String text, DiscoveredDevice device) async {
    if (text.isEmpty) return;
    final data = Uint8List.fromList(utf8.encode(text));
    final now = DateTime.now();
    final item = TransferItem(
      id: randomId(),
      name: '文字消息 · ${text.runes.length} 字',
      relativePath: '文字消息/${now.millisecondsSinceEpoch}.txt',
      size: data.length,
      data: data,
    );
    await sendItems([item], device);
  }

  Future<void> resume(String id) async {
    final control = _controls[id];
    if (control != null) return;
    final index = _records.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final record = _records[index];
    if (record.direction != TransferDirection.sending || record.item == null)
      return;
    // 旧版本可能因源文件尺寸报小只发了前半段；续传前清空哈希强制重算，
    // 以真实字节数覆盖 size，避免再次缩水（接收端会因元数据不符从头重收）。
    if (record.sha256.isNotEmpty) {
      _records[index] = record.revised(sha256: '');
    }
    unawaited(_sendQueue([id]));
  }

  Future<void> pause(String id) async {
    final control = _controls[id];
    if (control == null) return;
    control.pauseRequested = true;
    final record = _records.firstWhere((item) => item.id == id);
    _upsert(record.revised(status: TransferStatus.paused));
    // 发送方向：由发送循环检测到标志后串行发出 pause（避免并发写 socket）。
  }

  Future<void> cancel(String id) async {
    final control = _controls[id];
    if (control == null) return;
    control.cancelRequested = true;
    final record = _records.firstWhere((item) => item.id == id);
    _upsert(record.revised(status: TransferStatus.cancelled));
    final channel = control.channel;
    if (channel == null) return;
    // 串行写入 cancel；不 await 整条链路（避免 flush 卡死），紧接着拆连接
    // 解除发送循环可能卡在等 ack 上的阻塞。接收端把拆连视为取消。
    unawaited(channel.sendJson('cancel').catchError((_) {}));
    try {
      channel.socket.destroy();
    } catch (_) {}
  }

  Future<void> clearFinishedHistory() async {
    _records.removeWhere((record) => !record.active);
    historyStore.scheduleSave(_records);
    await historyStore.flush();
    notifyListeners();
  }

  /// 发送一批文件。
  ///
  /// 对标 LocalSend 的精华：同一目标设备的整批文件共用一条加密连接
  /// 逐个接力；旧实现每个文件都重新握手，小文件多时握手开销占比过高。
  /// 单个文件网络中断只重连该文件，已完成与未开始的部分不受影响；
  /// 接收端暂停/取消后流上无法对账，下一个文件重新建连。
  Future<void> _sendQueue(List<String> ids) async {
    var refused = false;
    SecureChannel? channel;
    for (final id in ids) {
      if (_controls.containsKey(id)) continue;
      if (refused) {
        // 对端已拒绝：本批剩余文件直接标记取消，不再逐个询问。
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.cancelled,
              error: '对端已拒绝接收，本批已停止',
            ));
        continue;
      }
      final control = _TransferControl();
      _controls[id] = control;
      try {
        var record = _records.firstWhere((entry) => entry.id == id);
        var item = record.item!;
        // 哈希与建连并行：大文件哈希不再串行挡在 10 秒直连超时前面。
        Future<({String hash, int size})>? hashFuture;
        if (record.sha256.isEmpty) {
          _upsert(
              record.revised(status: TransferStatus.hashing, clearError: true));
          hashFuture = gateway.hashItem(item);
        }
        // 发送期间持有源文件句柄，避免流水线高频分块反复 open/close。
        await gateway.holdItemHandle(item);

        var settled = false;
        var connectAttempts = 0;
        while (
            !settled && !control.pauseRequested && !control.cancelRequested) {
          record = _records.firstWhere((entry) => entry.id == id);
          if (channel == null) {
            _upsert(record.revised(
                status: TransferStatus.connecting, clearError: true));
            try {
              // 建连与哈希并行：过期局域网地址不再串行挡住整段哈希。
              final connectFuture = _openSenderChannel(record.deviceId);
              if (hashFuture != null &&
                  _records.firstWhere((entry) => entry.id == id).sha256.isEmpty) {
                final result = await hashFuture;
                hashFuture = null;
                record = _records.firstWhere((entry) => entry.id == id);
                if (result.size != item.size) {
                  item = TransferItem(
                    id: item.id,
                    name: item.name,
                    relativePath: item.relativePath,
                    size: result.size,
                    path: item.path,
                    uri: item.uri,
                    data: item.data,
                  );
                }
                _upsert(record.revised(
                  size: item.size,
                  sha256: result.hash,
                  item: item,
                ));
              }
              final opened = await connectFuture;
              if (opened == null) {
                _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                      status: TransferStatus.waiting,
                      error: '等待设备上线后自动续传',
                    ));
                await Future<void>.delayed(const Duration(seconds: 3));
                continue;
              }
              channel = opened;
              connectAttempts = 0;
              onSenderChannelOpened?.call();
            } catch (error) {
              if (error is! SocketException && error is! TimeoutException) {
                rethrow;
              }
              connectAttempts++;
              if (connectAttempts >= maxConnectAttempts) {
                throw StateError('连续 $connectAttempts 次连接失败，已停止自动重试；'
                    '设备恢复后点“继续”可续传');
              }
              _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                    status: TransferStatus.waiting,
                    error: '$error；将自动重试',
                  ));
              await Future<void>.delayed(Duration(
                  seconds: _retryBackoffSeconds[min(
                      connectAttempts - 1, _retryBackoffSeconds.length - 1)]));
              continue;
            }
          } else if (hashFuture != null &&
              _records.firstWhere((entry) => entry.id == id).sha256.isEmpty) {
            // 连接已有、哈希尚未完成（极少见）：补齐 offer 所需摘要。
            final result = await hashFuture;
            hashFuture = null;
            record = _records.firstWhere((entry) => entry.id == id);
            if (result.size != item.size) {
              item = TransferItem(
                id: item.id,
                name: item.name,
                relativePath: item.relativePath,
                size: result.size,
                path: item.path,
                uri: item.uri,
                data: item.data,
              );
            }
            _upsert(record.revised(
              size: item.size,
              sha256: result.hash,
              item: item,
            ));
          }
          try {
            final outcome = await _sendFileOnChannel(id, control, item, channel,
                onFirstAck: () => connectAttempts = 0);
            switch (outcome) {
              case _SendOutcome.completed:
              case _SendOutcome.verifyFailed:
                // 流上没有遗留数据，连接直接留给下一个文件接力。
                settled = true;
                break;
              case _SendOutcome.remotePaused:
                _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                      status: TransferStatus.paused,
                    ));
                settled = true;
                await _closeChannel(channel);
                channel = null;
                break;
              case _SendOutcome.remoteCancelled:
                _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                      status: TransferStatus.cancelled,
                    ));
                settled = true;
                await _closeChannel(channel);
                channel = null;
                break;
              case _SendOutcome.connectionLost:
                // 断点保留在接收端，重连后从 accept 的 offset 继续。
                connectAttempts++;
                if (connectAttempts >= maxConnectAttempts) {
                  throw StateError('连续 $connectAttempts 次连接中断，'
                      '已停止自动重试；设备恢复后点“继续”可续传');
                }
                await _closeChannel(channel);
                channel = null;
                _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                      status: TransferStatus.waiting,
                      error: '连接中断，正在自动重试',
                    ));
                await Future<void>.delayed(Duration(
                    seconds: _retryBackoffSeconds[min(connectAttempts - 1,
                        _retryBackoffSeconds.length - 1)]));
                break;
            }
          } on _PeerRefusedException {
            // 对端明确拒绝：当前文件失败，本批剩余全部取消并终止。
            rethrow;
          } on SocketException catch (error) {
            await _closeChannel(channel);
            channel = null;
            if (control.pauseRequested) {
              _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                    status: TransferStatus.paused,
                  ));
              settled = true;
            } else if (control.cancelRequested) {
              _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                    status: TransferStatus.cancelled,
                  ));
              settled = true;
            } else {
              connectAttempts++;
              if (connectAttempts >= maxConnectAttempts) {
                throw StateError('连续 $connectAttempts 次连接失败，'
                    '已停止自动重试；设备恢复后点“继续”可续传');
              }
              _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                    status: TransferStatus.waiting,
                    error: '$error；将自动重试',
                  ));
              await Future<void>.delayed(Duration(
                  seconds: _retryBackoffSeconds[min(
                      connectAttempts - 1, _retryBackoffSeconds.length - 1)]));
            }
          }
        }
      } on _PeerRefusedException catch (error) {
        refused = true;
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.failed,
              error: '$error',
            ));
      } catch (error) {
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.failed,
              error: '$error',
            ));
      } finally {
        final index = _records.indexWhere((entry) => entry.id == id);
        if (index >= 0 && _records[index].item != null) {
          unawaited(gateway.releaseItemHandles(_records[index].item!));
        }
        if (identical(_controls[id], control)) _controls.remove(id);
        onBackgroundMessage?.call('等待传输');
      }
    }
    await _closeChannel(channel);
    onBackgroundMessage?.call('等待传输');
  }

  /// 在发送循环里发出暂停/取消，保证与分块帧串行写入。
  Future<void> _signalStopIfNeeded(
    _TransferControl control,
    SecureChannel channel,
  ) async {
    if (control.cancelRequested) {
      await channel.flushSocket();
      try {
        await channel.sendJson('cancel');
      } catch (_) {}
      throw const SocketException('用户取消');
    }
    if (control.pauseRequested) {
      await channel.flushSocket();
      try {
        await channel.sendJson('pause');
      } catch (_) {}
      throw const SocketException('用户暂停');
    }
  }

  /// 直连与中继并行竞速；记住该设备最近成功路径。
  Future<SecureChannel?> _openSenderChannel(String deviceId) async {
    final endpoint = endpointFor(deviceId);
    final trusted = endpoint?.device ?? deviceStore.byId(deviceId);
    final memory = _pathMemory.putIfAbsent(deviceId, ConnectionPathMemory.new);
    final canDirect =
        endpoint != null && endpoint.host.isNotEmpty && endpoint.port > 0;
    final canRelay = relayDial != null && trusted != null;

    if (!canDirect && !canRelay) return null;

    Future<SecureChannel?> dialDirect() async {
      final directEndpoint = endpoint;
      if (directEndpoint == null ||
          directEndpoint.host.isEmpty ||
          directEndpoint.port <= 0) {
        return null;
      }
      Socket? socket;
      try {
        socket = await Socket.connect(
          directEndpoint.host,
          directEndpoint.port,
          timeout: directRaceTimeout,
        );
        return await SecureChannel.connect(
          socket,
          identity: identity,
          expectedDeviceId: directEndpoint.device.id,
          expectedPublicKey: base64Decode(directEndpoint.device.publicKey),
          handshakeTimeout: const Duration(seconds: 8),
        );
      } catch (_) {
        try {
          await socket?.close();
        } catch (_) {}
        return null;
      }
    }

    Future<SecureChannel?> dialRelay() async {
      final dial = relayDial;
      final peer = trusted;
      if (dial == null || peer == null) return null;
      Socket? relaySocket;
      try {
        relaySocket = await dial(deviceId);
        if (relaySocket == null) return null;
        return await SecureChannel.connect(
          relaySocket,
          identity: identity,
          expectedDeviceId: peer.id,
          expectedPublicKey: base64Decode(peer.publicKey),
          handshakeTimeout: const Duration(seconds: 8),
        );
      } catch (_) {
        try {
          await relaySocket?.close();
        } catch (_) {}
        return null;
      }
    }

    if (canDirect && canRelay) {
      final raced = await memory.race<SecureChannel>(
        direct: dialDirect,
        relay: dialRelay,
        onLose: (loser) => unawaited(_closeChannel(loser)),
      );
      return raced?.value;
    }
    if (canDirect) {
      final channel = await dialDirect();
      if (channel != null) memory.remember(TransferPathKind.direct);
      return channel;
    }
    final channel = await dialRelay();
    if (channel != null) memory.remember(TransferPathKind.relay);
    return channel;
  }

  /// 在已建立的加密连接上发送单个文件。
  ///
  /// 流水线：一次发出最多 [sendWindowDepth] 个分块而无需等逐块确认；
  /// 接收端通过 accept 回传 `pipeline` 表示支持，旧版本接收端不回传时
  /// 自动退回逐块确认（深度 1），保证与旧版互通。
  /// [onFirstAck] 在本文件收到第一个分块确认时回调（连接择优的进度信号）。
  Future<_SendOutcome> _sendFileOnChannel(
    String id,
    _TransferControl control,
    TransferItem item,
    SecureChannel channel, {
    void Function()? onFirstAck,
  }) async {
    var firstAck = true;
    control.channel = channel;
    try {
      await channel.sendJson('offer', {
        'id': item.id,
        'name': item.name,
        'relativePath': item.relativePath,
        'size': item.size,
        'sha256': _records.firstWhere((entry) => entry.id == id).sha256,
        'kind': item.isText ? 'text' : 'file',
        'pipeline': sendWindowDepth,
      });
      final accepted = await channel.read().timeout(
            const Duration(seconds: 120),
            onTimeout: () => throw const SocketException('等待接收端响应超时'),
          );
      if (accepted.type == 'refused') {
        throw _PeerRefusedException(
            accepted.header['message'] as String? ?? '对方未接收');
      }
      if (accepted.type == 'error') {
        throw StateError(accepted.header['message'] as String? ?? '接收失败');
      }
      if (accepted.type != 'accept') {
        throw const SocketException('接收端响应无效');
      }
      var ackedOffset = (accepted.header['offset'] as num).toInt();
      if (ackedOffset < 0 || ackedOffset > item.size) {
        throw const SocketException('续传位置无效');
      }
      final negotiated = (accepted.header['pipeline'] as num?)?.toInt() ?? 1;
      final windowBytes = transferChunkSize *
          (negotiated < 1
              ? 1
              : (negotiated > sendWindowDepth ? sendWindowDepth : negotiated));
      var sentOffset = ackedOffset;
      // 加密流水线：最多 cryptoDepth 块同时在池里并行加密，按序落 socket。
      final cryptoQueue = <Future<Uint8List>>[];
      var record = _records.firstWhere((entry) => entry.id == id);
      _upsert(record.revised(
        status: TransferStatus.transferring,
        bytesTransferred: ackedOffset,
        clearError: true,
      ));
      onBackgroundMessage?.call('正在传输 ${item.name}');

      while (ackedOffset < item.size || cryptoQueue.isNotEmpty) {
        if (control.cancelRequested || control.pauseRequested) {
          // 流水线可能已超前发出多块：停止时不再等剩余 ack，立刻发指令。
          cryptoQueue.clear();
          await _signalStopIfNeeded(control, channel);
        }
        // 读盘 + 提交加密（不等待加密完成），保持 cryptoDepth 块并行加密。
        while (cryptoQueue.length < cryptoDepth &&
            sentOffset - ackedOffset < windowBytes &&
            sentOffset < item.size &&
            !control.pauseRequested &&
            !control.cancelRequested) {
          final length = item.size - sentOffset > transferChunkSize
              ? transferChunkSize
              : item.size - sentOffset;
          final chunk = await gateway.readChunk(item, sentOffset, length);
          if (chunk.isEmpty || chunk.length < length) {
            // 源文件变短（被移动/修改）时立即失败，不能用短块凑出“完成”。
            throw StateError('源文件在传输时发生变化，已中止以保证原文件完整');
          }
          final plain = buildPlainFrame({
            'type': 'chunk',
            'id': item.id,
            'offset': sentOffset,
          }, chunk);
          final future = SecureChannel.cryptoPool.encryptFrame(plain, channel.keyBytes);
          cryptoQueue.add(future);
          sentOffset += chunk.length;
        }
        if (cryptoQueue.isNotEmpty) {
          // 发出最早一块：加密在池里并行，这里只等它的结果。
          final frame = await cryptoQueue.removeAt(0);
          if (control.cancelRequested || control.pauseRequested) {
            cryptoQueue.clear();
            await _signalStopIfNeeded(control, channel);
          }
          // 窗口未满时不 flush，避免每块一次刷盘把吞吐钉在 RTT。
          await channel.sendRawFrame(frame);
        }
        // 窗口打满，或（已到文件尾且加密队列全部发出）才等确认；
        // 队列未清空前不得等 ack：接收端预读可能在等还没发出的帧。
        if (sentOffset - ackedOffset >= windowBytes ||
            (cryptoQueue.isEmpty && sentOffset >= item.size)) {
          if (control.cancelRequested || control.pauseRequested) {
            cryptoQueue.clear();
            await _signalStopIfNeeded(control, channel);
          }
          await channel.flushSocket();
          final acknowledgement = await channel.read();
          if (acknowledgement.type == 'pause' ||
              acknowledgement.type == 'paused') {
            return _SendOutcome.remotePaused;
          }
          if (acknowledgement.type == 'cancel') {
            return _SendOutcome.remoteCancelled;
          }
          if (acknowledgement.type == 'error') {
            throw StateError(
                acknowledgement.header['message'] as String? ?? '接收失败');
          }
          if (acknowledgement.type != 'chunkAck') {
            throw StateError('接收端分块确认无效');
          }
          final acknowledged =
              (acknowledgement.header['offset'] as num?)?.toInt() ?? -1;
          if (acknowledged <= ackedOffset || acknowledged > sentOffset) {
            throw StateError('接收端分块确认无效');
          }
          if (firstAck) {
            // 有真实进度：重置连续失败计数（择优逻辑的进度信号）。
            firstAck = false;
            onFirstAck?.call();
          }
          ackedOffset = acknowledged;
          record = _records.firstWhere((entry) => entry.id == id);
          _upsertProgress(record.revised(
            status: TransferStatus.transferring,
            bytesTransferred: ackedOffset,
          ));
        }
      }
      await _signalStopIfNeeded(control, channel);
      await channel.sendJson('end', {'id': item.id});
      final result = await channel.read();
      if (result.type == 'verified') {
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.completed,
              bytesTransferred: item.size,
              savePath: result.header['savePath'] as String?,
              clearError: true,
            ));
        return _SendOutcome.completed;
      }
      if (result.type == 'verifyFailed') {
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.failed,
              bytesTransferred: 0,
              error: '哈希校验不一致，已保留原文件，可重新发送',
            ));
        return _SendOutcome.verifyFailed;
      }
      if (result.type == 'pause' || result.type == 'paused') {
        return _SendOutcome.remotePaused;
      }
      if (result.type == 'cancel') {
        return _SendOutcome.remoteCancelled;
      }
      if (result.type == 'error') {
        throw StateError(result.header['message'] as String? ?? '接收失败');
      }
      throw StateError(result.header['message'] as String? ?? '传输未完成');
    } on SocketException {
      // 流水线可能已多发出若干块：暂停/取消指令必须尽量送达，否则接收端会卡在等 end。
      if (control.cancelRequested) {
        try {
          await channel.sendJson('cancel');
        } catch (_) {}
      } else if (control.pauseRequested) {
        try {
          await channel.sendJson('pause');
        } catch (_) {}
      }
      rethrow;
    } finally {
      control.channel = null;
    }
  }

  /// 中继桥接进来的入站连接与本地 ServerSocket 走同一套握手与接收流程。
  Future<void> handleIncomingSocket(Socket socket) {
    return _handleConnection(socket);
  }

  Future<void> _handleConnection(Socket socket) async {
    SecureChannel? channel;
    try {
      channel = await SecureChannel.accept(
        socket,
        identity: identity,
        authorize: authorize,
      );
      while (true) {
        final message = await channel.read();
        switch (message.type) {
          case 'offer':
            await _receiveFile(channel, message.header);
            break;
          case 'ping':
            await channel.sendJson('pong');
            break;
          default:
            await channel.sendJson('error', {'message': '不支持的操作'});
            break;
        }
      }
    } on SocketException {
      // 配对完成或文件结束后，客户端主动关闭连接属于正常流程。
    } catch (error) {
      debugPrint('连接处理失败：$error');
    } finally {
      await _closeChannel(channel);
    }
  }

  Future<void> _receiveFile(
      SecureChannel channel, Map<String, dynamic> offer) async {
    final id = offer['id'] as String? ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id)) {
      await channel.sendJson('error', {'message': '传输编号无效'});
      return;
    }
    if (_activeReceiving.contains(id)) {
      await channel.sendJson('error', {'message': '相同文件正在接收，请稍候'});
      return;
    }
    _activeReceiving.add(id);
    final control = _TransferControl()..channel = channel;
    _controls[id] = control;
    RandomAccessFile? output;
    String? destinationKey;
    File? part;
    File? metadata;
    var status = TransferStatus.waiting;
    var receivedOffset = 0;
    try {
      final isText = offer['kind'] == 'text';
      final name = offer['name'] as String;
      final relativePath = isText
          ? '__text__/$id.txt'
          : safeRelativePath(offer['relativePath'] as String);
      if (_activeDestinations.contains(relativePath)) {
        await channel.sendJson('error', {'message': '相同保存路径正在接收，请稍候'});
        return;
      }
      _activeDestinations.add(relativePath);
      destinationKey = relativePath;
      final size = (offer['size'] as num).toInt();
      final expectedHash = offer['sha256'] as String;
      if (size < 0) throw const FormatException('文件大小无效');
      if (authorizeOffer != null) {
        final granted = await _consentGate(
          channel.peerId,
          name,
          size,
          isText,
          channel.peerName,
        );
        if (!granted) {
          status = TransferStatus.cancelled;
          _upsert(TransferRecord(
            id: id,
            deviceId: channel.peerId,
            deviceName: channel.peerName,
            name: name,
            relativePath: relativePath,
            size: size,
            direction: TransferDirection.receiving,
            status: TransferStatus.cancelled,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            sha256: expectedHash,
            isText: isText,
            error: '已拒绝接收',
          ));
          await channel.sendJson('refused', {'message': '对方未接收（已在接收端拒绝）'});
          return;
        }
      }
      final root = await gateway.receiveDirectory();
      final incoming = Directory(p.join(root.path, '.incoming'));
      await incoming.create(recursive: true);
      part = File(p.join(incoming.path, '$id.part'));
      metadata = File(p.join(incoming.path, '$id.json'));
      var offset = 0;
      if (await part.exists() && await metadata.exists()) {
        try {
          final saved =
              jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          if (saved['size'] == size && saved['sha256'] == expectedHash) {
            offset = await part.length();
            if (offset > size) offset = 0;
          }
        } catch (_) {
          offset = 0;
        }
      }
      receivedOffset = offset;
      if (offset == 0) {
        await metadata.writeAsString(jsonEncode({
          'name': name,
          'relativePath': relativePath,
          'size': size,
          'sha256': expectedHash,
        }));
      }
      final now = DateTime.now();
      final existingIndex = _records.indexWhere((record) => record.id == id);
      final record = TransferRecord(
        id: id,
        deviceId: channel.peerId,
        deviceName: channel.peerName,
        name: name,
        relativePath: relativePath,
        size: size,
        direction: TransferDirection.receiving,
        status: TransferStatus.transferring,
        createdAt: existingIndex >= 0 ? _records[existingIndex].createdAt : now,
        updatedAt: now,
        bytesTransferred: offset,
        sha256: expectedHash,
        isText: isText,
      );
      _upsert(record);
      // 协商流水线深度：新发送端会带 pipeline 字段，回传表示本端支持；
      // 旧发送端不带该字段时回 1，行为与逐块确认完全一致。
      final requestedWindow = (offer['pipeline'] as num?)?.toInt() ?? 1;
      await channel.sendJson('accept', {
        'offset': offset,
        'pipeline': requestedWindow < 1
            ? 1
            : (requestedWindow > sendWindowDepth
                ? sendWindowDepth
                : requestedWindow),
      });
      // 边写边算 SHA-256，避免收完后再整文件读盘一遍。
      // 续传时先读已有分块再打开写句柄，避免同文件双开冲突。
      final hashSink = AccumulatorSink<Digest>();
      final hashInput = sha256.startChunkedConversion(hashSink);
      final partFile = part as File;
      if (offset > 0 && await partFile.exists()) {
        await for (final prior in partFile.openRead(0, offset)) {
          hashInput.add(prior);
        }
      }
      output = await partFile.open(mode: FileMode.append);
      if (offset == 0) await output.truncate(0);
      await output.setPosition(offset);
      status = TransferStatus.transferring;
      var writtenSinceFlush = 0;
      // 解密流水线：预读最多 decryptDepth 帧并行解密，按序写盘+回执。
      final inflight = <Future<SecureMessage>>[];

      while (true) {
        if (control.pauseRequested) {
          await output.flush();
          status = TransferStatus.paused;
          _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                status: TransferStatus.paused,
                bytesTransferred: offset,
              ));
          await channel.sendJson('pause');
          return;
        }
        if (control.cancelRequested) {
          status = TransferStatus.cancelled;
          _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                status: TransferStatus.cancelled,
                bytesTransferred: offset,
              ));
          await channel.sendJson('cancel');
          return;
        }
        // 预读填满解密流水线：只在确定还有分块未到时预读，
        // 避免把 end 之后的 EOF 读穿（end 之后不会再有帧）。
        while (inflight.length < decryptDepth &&
            offset + inflight.length * transferChunkSize < size) {
          final raw = await channel.readRawFrame();
          inflight.add(channel.decryptRaw(raw));
        }
        final Future<SecureMessage> pending;
        if (inflight.isNotEmpty) {
          pending = inflight.removeAt(0);
        } else {
          // 只剩 end/控制帧：单帧直读。
          final raw = await channel.readRawFrame();
          pending = channel.decryptRaw(raw);
        }
        final message = await pending;
        if (message.type == 'chunk') {
          if (message.header['id'] != id)
            throw const SocketException('文件编号不匹配');
          final chunkOffset = (message.header['offset'] as num).toInt();
          if (chunkOffset != offset || message.payload.isEmpty) {
            throw const SocketException('文件分块顺序错误');
          }
          if (offset + message.payload.length > size) {
            throw const SocketException('文件分块超出声明大小');
          }
          await output.writeFrom(message.payload);
          hashInput.add(message.payload);
          offset += message.payload.length;
          receivedOffset = offset;
          writtenSinceFlush += message.payload.length;
          if (writtenSinceFlush >= 8 * 1024 * 1024) {
            await output.flush();
            writtenSinceFlush = 0;
          }
          // 流水线高吞吐下按约 100ms 节流刷新进度，避免 UI 逐块重建。
          final notified = _upsertProgress(
            _records.firstWhere((entry) => entry.id == id).revised(
                  bytesTransferred: offset,
                  status: TransferStatus.transferring,
                ),
          );
          if (notified) onBackgroundMessage?.call('正在接收 $name');
          await channel.sendJson('chunkAck', {'offset': offset});
          continue;
        }
        if (message.type == 'pause') {
          await output.flush();
          status = TransferStatus.paused;
          _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                status: TransferStatus.paused,
                bytesTransferred: offset,
              ));
          await channel.sendJson('paused');
          return;
        }
        if (message.type == 'cancel') {
          status = TransferStatus.cancelled;
          _upsert(_records.firstWhere((entry) => entry.id == id).revised(
                status: TransferStatus.cancelled,
                bytesTransferred: offset,
              ));
          await channel.sendJson('cancel');
          return;
        }
        if (message.type != 'end') throw const SocketException('传输指令无效');
        // 必须收满声明大小才允许进入校验，防止少发时也通过哈希造成缩水。
        if (offset != size) {
          throw SocketException('接收不完整：已收 $offset 字节，应为 $size 字节');
        }
        break;
      }

      await output.flush();
      await output.close();
      output = null;
      _upsert(_records.firstWhere((entry) => entry.id == id).revised(
            status: TransferStatus.verifying,
            bytesTransferred: offset,
          ));
      hashInput.close();
      final actualHash = hashSink.events.isEmpty
          ? sha256.convert(const <int>[]).toString()
          : hashSink.events.single.toString();
      if (actualHash != expectedHash) {
        final failed = await part.open(mode: FileMode.write);
        await failed.truncate(0);
        await failed.close();
        status = TransferStatus.failed;
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.failed,
              bytesTransferred: 0,
              error: 'SHA-256 校验不一致，文件未被标记为完成',
            ));
        await channel.sendJson('verifyFailed');
        return;
      }
      // 文字消息不落最终文件：校验通过后还原为正文，临时分块立即清理。
      if (isText) {
        final content = await part.readAsString();
        if (await metadata.exists()) await metadata.delete();
        await part.delete();
        status = TransferStatus.completed;
        _upsert(_records.firstWhere((entry) => entry.id == id).revised(
              status: TransferStatus.completed,
              bytesTransferred: size,
              isText: true,
              textContent: content,
              clearError: true,
            ));
        await channel.sendJson('verified', {'kind': 'text'});
        onBackgroundMessage?.call('等待传输');
        return;
      }
      final destination = await uniqueDestination(root, relativePath);
      await part.rename(destination.path);
      if (await metadata.exists()) await metadata.delete();
      status = TransferStatus.completed;
      _upsert(_records.firstWhere((entry) => entry.id == id).revised(
            status: TransferStatus.completed,
            bytesTransferred: size,
            savePath: destination.path,
            clearError: true,
          ));
      await channel.sendJson('verified', {'savePath': destination.path});
      onBackgroundMessage?.call('等待传输');
    } on SocketException catch (error) {
      // 发送端取消会拆掉连接；对端断连时接收侧统一记为取消并清理半截文件，
      // 避免卡在 transferring。发送端重连续传会重新 offer。
      if (status == TransferStatus.transferring ||
          status == TransferStatus.waiting) {
        status = TransferStatus.cancelled;
        final index = _records.indexWhere((entry) => entry.id == id);
        if (index >= 0) {
          _upsert(_records[index].revised(
            status: TransferStatus.cancelled,
            bytesTransferred: receivedOffset > 0 ? receivedOffset : null,
            error: '$error',
          ));
        }
        return;
      }
      rethrow;
    } catch (error) {
      if (status != TransferStatus.paused &&
          status != TransferStatus.cancelled &&
          status != TransferStatus.completed &&
          status != TransferStatus.failed) {
        final index = _records.indexWhere((entry) => entry.id == id);
        if (index >= 0) {
          _upsert(_records[index].revised(
            status: TransferStatus.failed,
            error: '$error',
          ));
        }
        try {
          await channel.sendJson('error', {'message': '$error'});
        } catch (_) {
          // 网络已断开时无法通知对端。
        }
      }
      rethrow;
    } finally {
      await output?.close();
      // 取消的传输不留半截文件：删掉 .part 与元数据，避免残留残缺品。
      // 暂停/失败仍保留 .part，供“继续”断点续传。
      if (status == TransferStatus.cancelled && part != null) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {
          // 文件被占用等情况下删除失败，不影响状态回执。
        }
        if (metadata != null) {
          try {
            if (await metadata.exists()) await metadata.delete();
          } catch (_) {}
        }
      }
      if (destinationKey != null) _activeDestinations.remove(destinationKey);
      if (identical(_controls[id], control)) _controls.remove(id);
      _activeReceiving.remove(id);
    }
  }

  /// 接收确认门：同一设备 60 秒内的会话只询问一次（批量只弹一次窗）；
  /// 拒绝同样记 60 秒，避免旧版本发送端自动重试造成弹窗轰炸。
  Future<bool> _consentGate(
    String peerId,
    String name,
    int size,
    bool isText,
    String peerName,
  ) async {
    final gate = authorizeOffer;
    if (gate == null) return true;
    final now = DateTime.now();
    _consentCache.removeWhere((_, at) => now.difference(at).inSeconds >= 60);
    _denyCache.removeWhere((_, at) => now.difference(at).inSeconds >= 60);
    if (_consentCache.containsKey(peerId)) return true;
    if (_denyCache.containsKey(peerId)) return false;
    final granted = await gate(IncomingOffer(
      name: name,
      size: size,
      isText: isText,
      peerName: peerName,
    ));
    if (granted) {
      _consentCache[peerId] = DateTime.now();
    } else {
      _denyCache[peerId] = DateTime.now();
    }
    return granted;
  }

  void _upsert(TransferRecord record, {bool notify = true}) {
    final index = _records.indexWhere((item) => item.id == record.id);
    final updated = record.revised(updatedAt: DateTime.now());
    // 速率采样：活动传输且字节数增长时喂样本；回退说明重开，作废旧样本。
    final previousBytes = index >= 0 ? _records[index].bytesTransferred : 0;
    if (updated.bytesTransferred > previousBytes && updated.active) {
      _throughput
          .putIfAbsent(updated.id, TransferThroughput.new)
          .add(updated.bytesTransferred, updated.updatedAt);
    } else if (updated.bytesTransferred < previousBytes || !updated.active) {
      _throughput.remove(updated.id);
    }
    if (index >= 0) {
      _records[index] = updated;
    } else {
      _records.add(updated);
    }
    if (_records.length > 200) {
      final removable = _records.indexWhere((item) => !item.active);
      if (removable >= 0) _records.removeAt(removable);
    }
    historyStore.scheduleSave(_records);
    if (notify && !_loading) notifyListeners();
  }

  /// 高频进度更新：状态总是最新，但 notifyListeners 按约 100ms 节流。
  bool _upsertProgress(TransferRecord record) {
    final now = DateTime.now();
    final due = now.difference(_lastProgressNotify).inMilliseconds >= 100;
    if (due) _lastProgressNotify = now;
    _upsert(record, notify: due);
    return due;
  }

  Future<void> _loadHistory() async {
    _loading = true;
    try {
      final loaded = await historyStore.load();
      for (final value in loaded) {
        var record = value;
        if (record.active) {
          record = record.revised(
            status: TransferStatus.failed,
            error: '应用已重新启动，可点击继续传输',
          );
        }
        _records.add(record);
      }
    } catch (_) {
      // 损坏的历史记录不影响配对与传输服务。
    }
    _loading = false;
  }

  Future<void> _closeChannel(SecureChannel? channel) async {
    if (channel == null) return;
    try {
      await channel.close();
    } catch (_) {
      // 对端先关闭时无需重复报错。
    }
  }

  Future<void> close() async {
    await historyStore.close();
    await _server?.close();
    _server = null;
    // 迭代副本：关闭通道会触发接收端 finally 并移除 _controls。
    for (final control in List.of(_controls.values)) {
      control.cancelRequested = true;
      await control.channel?.close();
    }
    _controls.clear();
    await gateway.closeAllHandles();
    // 给在途接收/发送的 finally 留一拍：释放文件句柄后再让上层退进程/删目录。
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

class _TransferControl {
  bool pauseRequested = false;
  bool cancelRequested = false;
  SecureChannel? channel;
}

extension TransferRecordRevision on TransferRecord {
  TransferRecord revised({
    String? deviceName,
    int? bytesTransferred,
    int? size,
    TransferItem? item,
    String? sha256,
    TransferStatus? status,
    String? error,
    bool clearError = false,
    String? savePath,
    bool? isText,
    String? textContent,
    DateTime? updatedAt,
  }) =>
      TransferRecord(
        id: id,
        deviceId: deviceId,
        deviceName: deviceName ?? this.deviceName,
        name: name,
        relativePath: relativePath,
        size: size ?? this.size,
        bytesTransferred: bytesTransferred ?? this.bytesTransferred,
        sha256: sha256 ?? this.sha256,
        direction: direction,
        status: status ?? this.status,
        error: clearError ? null : error ?? this.error,
        savePath: savePath ?? this.savePath,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        item: item ?? this.item,
        isText: isText ?? this.isText,
        textContent: textContent ?? this.textContent,
      );
}
