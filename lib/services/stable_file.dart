import 'dart:io';

/// 等待文件写完：连续两次观测到相同非零大小且间隔足够，才视为稳定。
///
/// Android `FileObserver` 的 `CLOSE_WRITE` / `MOVED_TO` 有时会在写入尚未完全
/// 落盘时触发；自动同步前用本函数避免传出半截文件。
Future<int> waitUntilFileStable(
  File file, {
  Duration pollInterval = const Duration(milliseconds: 350),
  int stableChecks = 2,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  var lastSize = -1;
  var stableCount = 0;
  while (DateTime.now().isBefore(deadline)) {
    if (!file.existsSync()) {
      await Future<void>.delayed(pollInterval);
      continue;
    }
    final size = file.lengthSync();
    if (size > 0 && size == lastSize) {
      stableCount++;
      if (stableCount >= stableChecks) return size;
    } else {
      lastSize = size;
      stableCount = size > 0 ? 1 : 0;
    }
    await Future<void>.delayed(pollInterval);
  }
  if (file.existsSync()) {
    final size = file.lengthSync();
    if (size > 0) return size;
  }
  throw StateError('等待文件写完超时：${file.path}');
}
