import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/speed_monitor.dart';

void main() {
  final base = DateTime(2026, 11, 19, 12);

  test('滚动窗口按首尾差计算每秒速率', () {
    final throughput = TransferThroughput();
    throughput.add(0, base);
    throughput.add(512 * 1024, base.add(const Duration(milliseconds: 500)));
    throughput.add(1024 * 1024, base.add(const Duration(seconds: 1)));
    final speed = throughput.bytesPerSecond();
    expect(speed, isNotNull);
    expect(speed! / (1024 * 1024), closeTo(1.0, 0.05));
  });

  test('样本间隔过短时不给出误导速率', () {
    final throughput = TransferThroughput();
    throughput.add(0, base);
    throughput.add(1024, base.add(const Duration(milliseconds: 50)));
    expect(throughput.bytesPerSecond(), isNull);
  });

  test('字节数回退时作废旧样本，重新累计', () {
    final throughput = TransferThroughput();
    throughput.add(1024 * 1024, base);
    throughput.add(512 * 1024, base.add(const Duration(seconds: 1)));
    expect(throughput.bytesPerSecond(), isNull);
    throughput.add(1024 * 1024, base.add(const Duration(seconds: 2)));
    throughput.add(2 * 1024 * 1024, base.add(const Duration(seconds: 3)));
    expect(throughput.bytesPerSecond(), isNotNull);
  });

  test('时间倒流的样本只刷新字节计数', () {
    final throughput = TransferThroughput();
    throughput.add(0, base);
    throughput.add(100, base.add(const Duration(seconds: 1)));
    throughput.add(200, base.add(const Duration(seconds: 1)));
    expect(throughput.bytesPerSecond(), closeTo(200, 1));
  });

  test('formatEta 换算成人话', () {
    expect(formatEta(1000, 30000), '30秒');
    expect(formatEta(1000, 90000), '1分30秒');
    expect(formatEta(1000, 3600 * 1000), '1小时');
    expect(formatEta(null, 1000), isNull);
    expect(formatEta(1000, 0), isNull);
  });
}
