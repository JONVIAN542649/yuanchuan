import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_models.dart';
import '../models/transfer_models.dart';
import 'identity_service.dart';
import 'transfer_manager.dart';

/// 聊天存储：按设备分会话，本地持久化，并把传输引擎的状态
/// 实时映射到消息上（发送/接收/进度/失败）。
///
/// 发送侧：聊天层自行构造 TransferItem（id = 消息 id），因此收发两端的
/// 消息 id 与传输 id 一致，天然对齐。
/// 接收侧：挂到 TransferManager 的通知上，为启动之后新出现的接收记录
/// 创建消息（历史记录只作基线，避免每次启动都重复建消息）。
class ChatStore extends ChangeNotifier {
  ChatStore({required this.transferManager});

  static const _prefix = 'local_file_drop.chat.';
  static const _deviceListKey = 'local_file_drop.chat.devices';

  final TransferManager transferManager;
  final Map<String, List<ChatMessage>> _byDevice = {};
  final Set<String> _seenTransferIds = {};
  Timer? _saveTimer;
  final Set<String> _dirtyDevices = {};
  void Function(String deviceId, ChatMessage message)? onIncoming;

  /// 有新消息（或进度变化）的设备，用于导航角标。
  final Set<String> devicesWithUnread = {};

  List<ChatMessage> messagesOf(String deviceId) =>
      List.unmodifiable(_byDevice[deviceId] ?? const []);

  Iterable<String> get deviceIds => _byDevice.keys;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceIds = preferences.getStringList(_deviceListKey) ?? const [];
    for (final deviceId in deviceIds) {
      final raw = preferences.getString('$_prefix$deviceId');
      if (raw == null) continue;
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        final messages = [
          for (final value in list)
            ChatMessage.fromJson(value as Map<String, dynamic>),
        ];
        _byDevice[deviceId] = messages;
        for (final message in messages) {
          final transferId = message.transferId;
          if (transferId != null) _seenTransferIds.add(transferId);
        }
      } catch (_) {
        // 单个会话损坏不影响其他会话。
      }
    }
    // 引擎里已存在的历史传输记录只作基线，不再生成消息。
    for (final record in transferManager.records) {
      _seenTransferIds.add(record.id);
    }
    transferManager.addListener(_onTransfersChanged);
  }

  /// 发送文字：id 与传输记录一致，两端消息天然对齐。
  Future<ChatMessage> sendText(
    DiscoveredDevice device,
    String text, {
    String? source,
  }) async {
    final bytes = utf8.encode(text);
    final now = DateTime.now();
    final message = ChatMessage(
      id: randomId(),
      deviceId: device.device.id,
      direction: ChatDirection.send,
      kind: ChatKind.text,
      timestamp: now,
      textContent: text,
      size: bytes.length,
      transferId: null,
      status: ChatStatus.transferring,
      source: source,
    );
    final item = TransferItem(
      id: message.id,
      name: '文字消息 · ${text.runes.length} 字',
      relativePath: '文字消息/${now.millisecondsSinceEpoch}.txt',
      size: bytes.length,
      data: Uint8List.fromList(bytes),
    );
    await _append(message);
    unawaited(
        transferManager.sendItems([item], device).catchError((Object error) {
      _markFailed(message.id, '$error');
    }));
    return message;
  }

  /// 发送文件 / 图片：每个文件一条消息。
  Future<List<ChatMessage>> sendFiles(
    DiscoveredDevice device,
    List<TransferItem> items, {
    String? source,
  }) async {
    final messages = <ChatMessage>[];
    for (final item in items) {
      final message = ChatMessage(
        id: item.id,
        deviceId: device.device.id,
        direction: ChatDirection.send,
        kind: chatKindIsImage(item.name) ? ChatKind.image : ChatKind.file,
        timestamp: DateTime.now(),
        fileName: item.name,
        filePath: item.path,
        size: item.size,
        status: ChatStatus.transferring,
        source: source,
      );
      messages.add(message);
      await _append(message);
    }
    unawaited(
        transferManager.sendItems(items, device).catchError((Object error) {
      for (final message in messages) {
        _markFailed(message.id, '$error');
      }
    }));
    return messages;
  }

  void markOpened(String deviceId) {
    devicesWithUnread.remove(deviceId);
    notifyListeners();
  }

  void clearConversation(String deviceId) {
    _byDevice.remove(deviceId);
    _dirtyDevices.add(deviceId);
    _scheduleSave();
    notifyListeners();
  }

  void _markFailed(String messageId, String error) {
    final message = _byId(messageId);
    if (message == null || message.finalized) return;
    _replace(message.copyWith(status: ChatStatus.failed, error: error));
  }

  ChatMessage? _byId(String messageId) {
    for (final messages in _byDevice.values) {
      for (final message in messages) {
        if (message.id == messageId) return message;
      }
    }
    return null;
  }

  void _onTransfersChanged() {
    var changed = false;
    for (final record in transferManager.records) {
      if (!_seenTransferIds.add(record.id)) continue;
      if (record.direction != TransferDirection.receiving) continue;
      // 接收侧：启动后新出现的记录 → 生成消息（自动接收，无需确认）。
      final message = ChatMessage(
        id: record.id,
        deviceId: record.deviceId,
        direction: ChatDirection.receive,
        kind: record.isTextRecord
            ? ChatKind.text
            : (chatKindIsImage(record.name) ? ChatKind.image : ChatKind.file),
        timestamp: record.createdAt,
        textContent: record.textContent,
        fileName: record.isTextRecord ? null : record.name,
        filePath: record.savePath,
        size: record.size,
        transferId: record.id,
        status: record.status == TransferStatus.completed
            ? ChatStatus.received
            : ChatStatus.transferring,
        error: record.error,
      );
      _byDevice.putIfAbsent(record.deviceId, () => []);
      _byDevice[record.deviceId]!.add(message);
      _dirtyDevices.add(record.deviceId);
      devicesWithUnread.add(record.deviceId);
      changed = true;
      onIncoming?.call(record.deviceId, message);
    }
    // 既有消息的进度/终态同步。
    for (final record in transferManager.records) {
      final message = _byId(record.id);
      if (message == null) continue;
      final updated = _statusFor(record);
      if (updated == null) continue;
      _replace(message.copyWith(
        textContent: record.textContent ?? message.textContent,
        filePath: record.savePath ?? message.filePath,
        status: updated,
        error: record.error,
        clearError: record.error == null,
      ));
      changed = true;
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  ChatStatus? _statusFor(TransferRecord record) {
    switch (record.status) {
      case TransferStatus.hashing:
      case TransferStatus.waiting:
      case TransferStatus.connecting:
      case TransferStatus.transferring:
      case TransferStatus.verifying:
        return ChatStatus.transferring;
      case TransferStatus.completed:
        return record.direction == TransferDirection.sending
            ? ChatStatus.sent
            : ChatStatus.received;
      case TransferStatus.failed:
        return ChatStatus.failed;
      case TransferStatus.cancelled:
        return ChatStatus.cancelled;
      case TransferStatus.paused:
        return null; // 暂停保持 transferring 展示，进度条停住即可。
    }
  }

  void _replace(ChatMessage updated) {
    final messages = _byDevice[updated.deviceId];
    if (messages == null) return;
    final index = messages.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    messages[index] = updated;
    _dirtyDevices.add(updated.deviceId);
  }

  Future<void> _append(ChatMessage message) async {
    _byDevice.putIfAbsent(message.deviceId, () => []);
    _byDevice[message.deviceId]!.add(message);
    _seenTransferIds.add(message.id);
    _dirtyDevices.add(message.deviceId);
    _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(milliseconds: 600), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    final devices = _dirtyDevices.isEmpty
        ? _byDevice.keys.toList()
        : _dirtyDevices.toList();
    _dirtyDevices.clear();
    for (final deviceId in devices) {
      final messages = _byDevice[deviceId] ?? const <ChatMessage>[];
      final trimmed = messages.length > chatMaxMessagesPerDevice
          ? messages.sublist(messages.length - chatMaxMessagesPerDevice)
          : messages;
      final encoded = [
        for (final message in trimmed) _persistable(message).toJson(),
      ];
      await preferences.setString('$_prefix$deviceId', jsonEncode(encoded));
    }
    await preferences.setStringList(_deviceListKey, _byDevice.keys.toList());
  }

  /// 持久化裁剪：文字超长截断，未完成的消息按失败落盘（重启后显示可重发）。
  ChatMessage _persistable(ChatMessage message) {
    var text = message.textContent;
    if (text != null && text.length > chatPersistTextLimit) {
      text = '${text.substring(0, chatPersistTextLimit)}\n…（超长已截断）';
    }
    final status = message.active ? ChatStatus.failed : message.status;
    return message.copyWith(
      textContent: text,
      status: status,
      error: message.error ?? (message.active ? '应用已重启，请重新发送' : null),
    );
  }

  @override
  void dispose() {
    transferManager.removeListener(_onTransfersChanged);
    _saveTimer?.cancel();
    super.dispose();
  }
}
