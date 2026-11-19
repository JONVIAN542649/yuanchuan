import 'dart:io';

/// 根据 IPv4 地址与前缀长度计算定向广播地址。
///
/// 例：`192.168.1.10/24` → `192.168.1.255`；`10.0.0.5/16` → `10.0.255.255`。
InternetAddress ipv4DirectedBroadcast(String address, int prefixLength) {
  if (prefixLength < 0 || prefixLength > 32) {
    throw ArgumentError.value(prefixLength, 'prefixLength', '须在 0..32');
  }
  final parts = address.split('.');
  if (parts.length != 4) {
    throw ArgumentError.value(address, 'address', '须为 IPv4');
  }
  var ip = 0;
  for (final part in parts) {
    final octet = int.parse(part);
    if (octet < 0 || octet > 255) {
      throw ArgumentError.value(address, 'address', '非法 IPv4');
    }
    ip = (ip << 8) | octet;
  }
  final mask =
      prefixLength == 0 ? 0 : (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
  final broadcast = (ip & mask) | (~mask & 0xFFFFFFFF);
  return InternetAddress(
    [
      (broadcast >> 24) & 0xFF,
      (broadcast >> 16) & 0xFF,
      (broadcast >> 8) & 0xFF,
      broadcast & 0xFF,
    ].join('.'),
  );
}

/// 从 `ip -4 -o addr` 风格输出解析 `(地址, 前缀)`。
///
/// 例：`2: wlan0    inet 192.168.1.10/23 brd ...`
List<({String address, int prefixLength})> parseIpDashOAddr(String stdout) {
  final result = <({String address, int prefixLength})>[];
  final re = RegExp(r'inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)');
  for (final match in re.allMatches(stdout)) {
    final address = match.group(1)!;
    final prefix = int.parse(match.group(2)!);
    if (prefix >= 0 && prefix <= 32) {
      result.add((address: address, prefixLength: prefix));
    }
  }
  return result;
}

/// 在无法取得真实前缀时的兼容回退：按 /24 推断（旧行为）。
InternetAddress fallbackSlash24Broadcast(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    throw ArgumentError.value(address, 'address');
  }
  return InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
}

/// 查询本机 IPv4 地址对应的前缀长度。
///
/// Linux/Android：优先解析 `ip -4 -o addr`；失败则返回空映射（调用方回退 /24）。
Future<Map<String, int>> lookupIpv4Prefixes() async {
  try {
    final result = await Process.run('ip', const ['-4', '-o', 'addr']);
    if (result.exitCode == 0) {
      final parsed = parseIpDashOAddr('${result.stdout}');
      return {
        for (final entry in parsed) entry.address: entry.prefixLength,
      };
    }
  } catch (_) {}
  return {};
}
