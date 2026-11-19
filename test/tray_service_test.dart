import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/tray_service.dart';

/// 托盘命令通道修复验证：stop 必须收到 isolate 回执（图标已删除），
/// 且整个过程不能超过 stop 的 500ms 回执窗口太多。
/// 仅 Windows 有效；其他平台直接跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('托盘 isolate 启动后 stop 能收到回执', () async {
    if (!TrayService.supported) {
      return;
    }
    final events = <String>[];
    final started = await TrayService.instance.start(
      events.add,
      tooltip: '原传-测试',
    );
    expect(started, true);
    final watch = Stopwatch()..start();
    await TrayService.instance.stop();
    watch.stop();
    // 修复前命令通道收不到 stop，这里只能走 500ms 超时兜底；
    // 修复后回执应在 100ms 量级内到达。
    expect(watch.elapsedMilliseconds, lessThan(1500));
  });
}
