import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 打开本机文件：Windows 用资源管理器定位，Android 走系统 VIEW。
/// 传输页与聊天气泡共用。
Future<void> openLocalFile(BuildContext context, String path) async {
  if (path.isEmpty) return;
  final file = File(path);
  if (!await file.exists()) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('文件已不存在或已移动')));
    return;
  }
  if (Platform.isWindows) {
    // explorer /select 会打开资源管理器并高亮选中该文件。
    await Process.run('explorer.exe', ['/select,$path']);
    return;
  }
  try {
    await const MethodChannel('local_file_drop/system')
        .invokeMethod<bool>('openPath', path);
  } on PlatformException {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开该文件')));
    }
  }
}
