import 'dart:async';
import 'dart:io';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import '../models/transfer_models.dart';
import '../services/app_state.dart';
import '../services/speed_monitor.dart';
import 'open_util.dart';

/// 聊天页：所有文字 / 图片 / 文件传输的统一入口。
/// 接收默认自动入库（配合设置里的"接收前询问"可改为手动确认）。
class ChatPage extends StatefulWidget {
  const ChatPage({required this.appState, super.key});

  final AppState appState;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  String? _selectedDeviceId;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.appState.chatStore.addListener(_onStoreChanged);
    _selectDefaultDevice();
  }

  @override
  void dispose() {
    widget.appState.chatStore.removeListener(_onStoreChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    final store = widget.appState.chatStore;
    if (_selectedDeviceId != null) store.markOpened(_selectedDeviceId!);
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _selectDefaultDevice() {
    final devices = widget.appState.devices;
    if (_selectedDeviceId == null && devices.isNotEmpty) {
      _selectedDeviceId = devices.first.device.id;
    }
    final store = widget.appState.chatStore;
    if (_selectedDeviceId != null) store.markOpened(_selectedDeviceId!);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _sendText() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _selectedDeviceId == null || _sending) return;
    final device = _deviceById(_selectedDeviceId!);
    if (device == null) return;
    setState(() => _sending = true);
    _inputController.clear();
    try {
      await widget.appState.chatStore.sendText(device, text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  Future<void> _pickAndSend({required bool images}) async {
    if (_selectedDeviceId == null) return;
    final device = _deviceById(_selectedDeviceId!);
    if (device == null) return;
    final gateway = widget.appState.gateway;
    final items =
        images ? await gateway.pickImages() : await gateway.pickFiles();
    if (items.isEmpty) return;
    await widget.appState.chatStore.sendFiles(device, items);
    _scrollToBottom();
  }

  DiscoveredDevice? _deviceById(String id) {
    for (final device in widget.appState.devices) {
      if (device.device.id == id) return device;
    }
    return null;
  }

  TransferRecord? _recordOf(ChatMessage message) {
    final transferId = message.transferId;
    if (transferId == null) return null;
    for (final record in widget.appState.transferManager.records) {
      if (record.id == transferId) return record;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.appState.chatStore;
    final devices = widget.appState.devices;
    _selectDefaultDevice();
    final selected = _selectedDeviceId;
    final messages =
        selected == null ? const <ChatMessage>[] : store.messagesOf(selected);
    final device = selected == null ? null : _deviceById(selected);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          children: [
            _buildDeviceBar(devices, selected),
            const Divider(height: 1, color: Color(0xFFE5E9EB)),
            Expanded(
              child: messages.isEmpty
                  ? _buildEmptyState(device)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) => _buildBubble(
                        messages[index],
                        deviceName: device?.device.name ?? '设备',
                      ),
                    ),
            ),
            const Divider(height: 1, color: Color(0xFFE5E9EB)),
            _buildComposer(selected != null && device != null),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceBar(List<DiscoveredDevice> devices, String? selected) {
    final store = widget.appState.chatStore;
    return SizedBox(
      height: 52,
      child: devices.isEmpty
          ? const Center(
              child: Text('还没有配对设备，先到"设备"页完成配对',
                  style: TextStyle(fontSize: 13, color: Color(0xFF5A6A70))),
            )
          : ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final device in devices)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: device.device.id == selected,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(device.device.name),
                          if (store.devicesWithUnread
                              .contains(device.device.id))
                            const SizedBox(width: 6),
                          if (store.devicesWithUnread
                              .contains(device.device.id))
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFFE53935),
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                      onSelected: (_) {
                        setState(() => _selectedDeviceId = device.device.id);
                        store.markOpened(device.device.id);
                        _scrollToBottom();
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(DiscoveredDevice? device) {
    final name = device?.device.name;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            device?.online == true ? Icons.chat_bubble_outline : Icons.link_off,
            size: 52,
            color: const Color(0xFF9AA7AB),
          ),
          const SizedBox(height: 14),
          Text(
            name == null ? '选择上方设备开始聊天' : '与 $name 的聊天',
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF37474F)),
          ),
          const SizedBox(height: 6),
          Text(
            device?.online == true
                ? '发文字、图片、文件都直接到对方聊天框，自动接收'
                : '设备暂时离线，发出的内容会在设备上线后自动续传',
            style: const TextStyle(fontSize: 13, color: Color(0xFF5A6A70)),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(bool enabled) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(
          children: [
            IconButton(
              tooltip: '发文件',
              onPressed: enabled ? () => _pickAndSend(images: false) : null,
              icon: const Icon(Icons.attach_file, color: Color(0xFF54666B)),
            ),
            IconButton(
              tooltip: '发图片',
              onPressed: enabled ? () => _pickAndSend(images: true) : null,
              icon: const Icon(Icons.image_outlined, color: Color(0xFF54666B)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _inputController,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendText(),
                decoration: InputDecoration(
                  hintText: enabled ? '输入消息，回车发送' : '选择设备后开始聊天',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF087F8C),
                minimumSize: const Size(44, 44),
                padding: EdgeInsets.zero,
              ),
              onPressed: enabled ? _sendText : null,
              child: const Icon(Icons.send, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(ChatMessage message, {required String deviceName}) {
    final sending = message.direction == ChatDirection.send;
    final record = _recordOf(message);
    final rec = record;
    final statusLine = _statusLine(message, record);
    final speed = rec != null && message.active
        ? widget.appState.transferManager.speedOf(rec.id)
        : null;
    final eta = speed == null || rec == null
        ? null
        : formatEta(speed, rec.size - rec.bytesTransferred);
    final bubbleColor = sending ? const Color(0xFF087F8C) : Colors.white;
    final textColor = sending ? Colors.white : const Color(0xFF212B2E);
    final maxWidth = MediaQuery.of(context).size.width * 0.66;
    return Align(
      alignment: sending ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(sending ? 14 : 3),
            bottomRight: Radius.circular(sending ? 3 : 14),
          ),
          border: sending ? null : Border.all(color: const Color(0xFFE5E9EB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.source != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('来自自动同步 · ${message.source}',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: sending
                            ? Colors.white70
                            : const Color(0xFF9AA7AB))),
              ),
            _buildContent(message, sending, textColor),
            if (statusLine != null) ...[
              const SizedBox(height: 4),
              Text(statusLine,
                  style: TextStyle(
                      fontSize: 11,
                      color: sending
                          ? Colors.white70
                          : (message.status == ChatStatus.failed
                              ? Colors.red.shade700
                              : const Color(0xFF5A6A70)))),
            ],
            if (message.active && record != null) ...[
              const SizedBox(height: 5),
              SizedBox(
                width: 180,
                child: LinearProgressIndicator(
                  value: record.progress.clamp(0, 1),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(3),
                  backgroundColor:
                      sending ? Colors.white24 : const Color(0xFFE5E9EB),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF087F8C)),
                ),
              ),
              if (speed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '${formatBytes(speed)}/s${eta == null ? '' : ' · 剩余 $eta'}',
                    style: TextStyle(
                        fontSize: 10.5,
                        color:
                            sending ? Colors.white70 : const Color(0xFF5A6A70)),
                  ),
                ),
            ],
            const SizedBox(height: 3),
            Text(_timeLabel(message.timestamp),
                style: TextStyle(
                    fontSize: 10,
                    color: sending ? Colors.white60 : const Color(0xFF9AA7AB))),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ChatMessage message, bool sending, Color textColor) {
    switch (message.kind) {
      case ChatKind.text:
        final text = message.textContent ?? message.fileName ?? '';
        return SelectableText(
          text,
          style: TextStyle(fontSize: 14, height: 1.4, color: textColor),
        );
      case ChatKind.image:
        final path = message.filePath;
        Widget content;
        if (path != null && File(path).existsSync()) {
          content = ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 180),
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fileRow(message, textColor),
              ),
            ),
          );
        } else {
          content = _fileRow(message, textColor);
        }
        if (message.finalized) {
          content = GestureDetector(
            onTap: path == null
                ? null
                : () => unawaited(openLocalFile(context, path)),
            child: content,
          );
        }
        return content;
      case ChatKind.file:
        return GestureDetector(
          onTap: message.finalized && message.filePath != null
              ? () => unawaited(openLocalFile(context, message.filePath!))
              : null,
          child: _fileRow(message, textColor),
        );
    }
  }

  Widget _fileRow(ChatMessage message, Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          message.kind == ChatKind.image
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined,
          size: 18,
          color: textColor,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            message.fileName ?? '文件',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, color: textColor),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          formatBytes(message.size),
          style: TextStyle(
              fontSize: 11,
              color: sendingSubtle(message.direction)
                  ? Colors.white70
                  : const Color(0xFF5A6A70)),
        ),
      ],
    );
  }

  bool sendingSubtle(ChatDirection direction) =>
      direction == ChatDirection.send;

  String? _statusLine(ChatMessage message, TransferRecord? record) {
    if (record != null && record.error != null) return record.error;
    if (message.error != null) return message.error;
    return switch (message.status) {
      ChatStatus.pending => '等待发送',
      ChatStatus.transferring => '传输中…',
      ChatStatus.sent => '已发送',
      ChatStatus.received => '已自动接收',
      ChatStatus.failed => '失败，可从设备页重发',
      ChatStatus.cancelled => '已取消',
    };
  }

  String _timeLabel(DateTime time) {
    final now = DateTime.now();
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    return '${time.month}/${time.day} $hh:$mm';
  }
}
