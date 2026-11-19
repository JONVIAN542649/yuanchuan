import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/transfer_models.dart';
import 'identity_service.dart';
import 'ipv4_broadcast.dart';

const discoveryPort = 47653;
const transferPort = 47654;

class DiscoveryService {
  DiscoveryService({
    required this.identity,
    required this.onDevice,
    this.prefixLookup = lookupIpv4Prefixes,
  });

  final DeviceIdentity identity;
  final void Function(DiscoveredDevice device) onDevice;

  /// 可注入：返回本机 IPv4 → 前缀长度；测试可替掉。
  final Future<Map<String, int>> Function() prefixLookup;

  RawDatagramSocket? _socket;
  Timer? _timer;
  Map<String, int> _prefixByAddress = {};
  var _announceCount = 0;

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _handle(datagram);
    });
    await _refreshPrefixes();
    await announce();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => announce());
  }

  Future<void> _refreshPrefixes() async {
    try {
      _prefixByAddress = await prefixLookup();
    } catch (_) {
      _prefixByAddress = {};
    }
  }

  Future<void> announce() async {
    final socket = _socket;
    if (socket == null) return;
    // 约每 30 秒刷新前缀，适应 DHCP / 漫游换网段。
    if (_prefixByAddress.isEmpty || _announceCount % 15 == 0) {
      await _refreshPrefixes();
    }
    _announceCount++;
    final payload = utf8.encode(jsonEncode({
      'app': 'LocalFileDrop',
      'version': 1,
      'id': identity.id,
      'name': identity.name,
      'publicKey': identity.publicKeyBase64,
      'port': transferPort,
      'platform': Platform.operatingSystem,
    }));
    final targets = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          final prefix = _prefixByAddress[ip];
          final broadcast = prefix != null
              ? ipv4DirectedBroadcast(ip, prefix)
              : fallbackSlash24Broadcast(ip);
          targets[broadcast.address] = broadcast;
        }
      }
    } catch (_) {
      // 全局广播仍可用于大多数普通局域网。
    }
    for (final target in targets.values) {
      try {
        socket.send(payload, target, discoveryPort);
      } catch (_) {
        // 某块网卡不支持广播时，不影响其他网卡。
      }
    }
  }

  void _handle(Datagram datagram) {
    try {
      final json =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      if (json['app'] != 'LocalFileDrop' || json['version'] != 1) return;
      if (json['id'] == identity.id) return;
      final device = TrustedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        publicKey: json['publicKey'] as String,
        platform: json['platform'] as String? ?? 'unknown',
      );
      onDevice(DiscoveredDevice(
        device: device,
        host: datagram.address.address,
        port: json['port'] as int,
        lastSeen: DateTime.now(),
      ));
    } catch (_) {
      // 忽略局域网内其他程序产生的无效广播。
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    final socket = _socket;
    _socket = null;
    socket?.close();
  }
}

Future<String> localIPv4Address() =>
    localIPv4Addresses().then((list) => list.first);

/// 返回本机全部可用的私网 IPv4 候选地址，按网卡可信度排序。
/// 手机配对时会逐个竞速尝试，因此多网卡时不再依赖单一选择。
Future<List<String>> localIPv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  final candidates = <_LanAddress>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!_isPrivateIPv4(address.address)) continue;
      if (_isVirtualInterface(interface.name)) continue;
      candidates.add(_LanAddress(
        address: address.address,
        score: _interfaceScore(interface.name),
      ));
    }
  }
  if (candidates.isEmpty) {
    throw SocketException('未找到真实的局域网 IPv4 地址，请连接 Wi-Fi 或手机热点');
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  final addresses = <String>[];
  for (final candidate in candidates) {
    if (!addresses.contains(candidate.address)) {
      addresses.add(candidate.address);
    }
  }
  return addresses;
}

bool _isPrivateIPv4(String address) {
  if (address.startsWith('192.168.') || address.startsWith('10.')) return true;
  final parts = address.split('.');
  return parts.length == 4 &&
      parts[0] == '172' &&
      int.tryParse(parts[1]) != null &&
      int.parse(parts[1]) >= 16 &&
      int.parse(parts[1]) <= 31;
}

bool _isVirtualInterface(String name) {
  final lower = name.toLowerCase();
  const markers = [
    'vmware',
    'vmnet',
    'virtual',
    'vbox',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'tailscale',
    'zerotier',
    'docker',
    'wsl',
    'bluetooth',
    '蓝牙',
    'tap',
  ];
  return markers.any(lower.contains);
}

int _interfaceScore(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('wlan') ||
      lower.contains('wi-fi') ||
      lower.contains('wifi')) {
    return 100;
  }
  if (lower.contains('ethernet') ||
      lower.contains('eth') ||
      lower.contains('以太网')) {
    return 90;
  }
  return 10;
}

class _LanAddress {
  const _LanAddress({
    required this.address,
    required this.score,
  });

  final String address;
  final int score;
}
