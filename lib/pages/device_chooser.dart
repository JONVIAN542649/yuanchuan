// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';

/// 为拖入的文件挑选发送目标：
/// 恰好一台在线 → 直接返回；多台在线 → 弹窗选择；无在线设备 → 提示并返回 null。
Future<DiscoveredDevice?> chooseOnlineDevice(
  BuildContext context,
  AppState appState,
) async {
  final online = appState.onlineDevices;
  if (online.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有在线的信任设备；请确认对方已打开原传并在同一局域网'),
      ));
    }
    return null;
  }
  if (online.length == 1) return online.single;
  if (!context.mounted) return null;
  return showDialog<DiscoveredDevice>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('发送到哪台设备？'),
      children: [
        for (final device in online)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, device),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices),
              title: Text(device.device.name),
              subtitle: Text(device.host),
            ),
          ),
      ],
    ),
  );
}
