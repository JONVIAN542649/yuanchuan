import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/ipv4_broadcast.dart';

void main() {
  test('/24 定向广播', () {
    expect(
      ipv4DirectedBroadcast('192.168.1.10', 24).address,
      '192.168.1.255',
    );
  });

  test('/23 校园网前缀不是 x.x.x.255', () {
    expect(
      ipv4DirectedBroadcast('10.20.30.40', 23).address,
      '10.20.31.255',
    );
  });

  test('/16 定向广播', () {
    expect(
      ipv4DirectedBroadcast('172.16.5.9', 16).address,
      '172.16.255.255',
    );
  });

  test('解析 ip -o addr 输出', () {
    const stdout = '''
1: lo    inet 127.0.0.1/8 scope host lo
2: wlan0    inet 192.168.1.10/23 brd 192.168.1.255 scope global wlan0
3: eth0    inet 10.0.0.5/16 scope global eth0
''';
    final parsed = parseIpDashOAddr(stdout);
    expect(parsed, hasLength(3));
    expect(
      parsed.firstWhere((e) => e.address == '192.168.1.10').prefixLength,
      23,
    );
    expect(
      parsed.firstWhere((e) => e.address == '10.0.0.5').prefixLength,
      16,
    );
  });

  test('/24 回退与旧行为一致', () {
    expect(fallbackSlash24Broadcast('192.168.8.3').address, '192.168.8.255');
  });
}
