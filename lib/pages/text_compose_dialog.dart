import 'dart:async';
import 'dart:math' as math;

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';

/// 双端共用的文字发送入口：没有 maxLength，不做字符截断。
Future<bool> composeAndSendText(
  BuildContext context,
  AppState appState,
  DiscoveredDevice device,
) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => _TextComposeDialog(deviceName: device.device.name),
  );
  if (text == null || text.isEmpty) return false;
  unawaited(appState.sendText(device, text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已开始发送到 ${device.device.name}')),
    );
  }
  return true;
}

class _TextComposeDialog extends StatefulWidget {
  const _TextComposeDialog({required this.deviceName});

  final String deviceName;

  @override
  State<_TextComposeDialog> createState() => _TextComposeDialogState();
}

class _TextComposeDialogState extends State<_TextComposeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(screen.width - 48, 560.0);
    final height = math.min(screen.height * 0.58, 440.0);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('发送文字',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            '到 ${widget.deviceName} · 内容走加密分块通道',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF5A6A70)),
          ),
        ],
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: TextField(
          controller: _controller,
          autofocus: true,
          expands: true,
          minLines: null,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 14, height: 1.5),
          decoration: const InputDecoration(
            hintText: '粘贴或输入任意长度文字，不限字数…',
            alignLabelWithHint: true,
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 16, 16),
      actions: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => Text(
            '${value.text.runes.length} 字 · 无长度上限',
            style: const TextStyle(fontSize: 12, color: Color(0xFF5A6A70)),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton.icon(
            onPressed: value.text.isEmpty
                ? null
                : () => Navigator.pop(context, value.text),
            icon: const Icon(Icons.send, size: 17),
            label: const Text('发送'),
          ),
        ),
      ],
    );
  }
}
