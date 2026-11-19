import 'dart:async';
import 'dart:io';

import 'line_buffer.dart';

/// 跨网中继客户端：电脑与手机不在同一网络时，经自建中继服务器桥接。
///
/// 协议（首行 ASCII 命令，之后字节全部被服务器桥接）：
/// - `ROOM <key>`      拨号/等待
/// - `BRIDGE <key>`    监听端收到 INCOMING 后开启的桥接连接
/// - `LISTEN <key>`    常驻监听，收到拨号时会读到 `INCOMING <key>`
/// - `PING`            保活
///
/// 载荷在其上仍走 SecureChannel 端到端加密，中继只见握手元数据与密文。
class RelayService {
  RelayService({required this.selfId, required this.onIncomingConnection});

  /// 自建中继（东京 VPS）。个人工具，地址内置于应用。
  static const defaultRelayHost = '38.175.203.162';
  static const defaultRelayPort = 47660;
  static String get defaultRelayAddress =>
      '$defaultRelayHost:$defaultRelayPort';

  /// 收发数据的房间前缀：按设备 id 一对一拨号。
  static String dataKey(String peerId) => 'D:$peerId';

  /// 配对会话房间前缀。
  static String pairingKey(String token) => 'P:$token';

  final String selfId;
  final Future<void> Function(Socket socket) onIncomingConnection;

  Socket? _listenerSocket;
  StreamIterator<List<int>>? _listenerIterator;
  Timer? _keepalive;
  bool _running = false;
  final Set<Socket> _heldSockets = {};

  static Future<bool> reachable({
    String host = defaultRelayHost,
    int port = defaultRelayPort,
  }) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      unawaited(socket.close());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 拨号：与对端（或等待中的另一方）建立桥接，返回可直接用于
  /// SecureChannel 握手的 socket。
  static Future<Socket> dial(
    String key, {
    String host = defaultRelayHost,
    int port = defaultRelayPort,
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.add('ROOM $key\n'.codeUnits);
    await socket.flush();
    return socket;
  }

  /// 配对等待：电脑端在配对窗口期内占用房间等待手机拨号。
  ///
  /// [onPaired] 在有对端接入时被调用，用于在该 socket 上完成安全握手。
  /// 必须提供，否则手机拨入后发出的 hello 无人应答，会一直卡在“正在配对”。
  Future<void> holdPairingRoom(
    String key, {
    Duration ttl = const Duration(minutes: 5),
    Future<void> Function(Socket socket)? onPaired,
  }) async {
    final socket = await dial(key);
    _heldSockets.add(socket);
    unawaited(() async {
      if (onPaired != null) {
        // 对端拨入后由回调完成握手；内部超时不得超过房间有效期。
        await onPaired(socket);
      } else {
        await Future<void>.delayed(ttl);
      }
      if (_heldSockets.remove(socket)) {
        try {
          await socket.close();
        } catch (_) {}
      }
    }());
  }

  void releaseHeldRooms() {
    for (final socket in List<Socket>.of(_heldSockets)) {
      _heldSockets.remove(socket);
      try {
        socket.close();
      } catch (_) {}
    }
  }

  /// 开始常驻监听 `D:<selfId>`，接收方通过它获得经中继进来的传输连接。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    // 定期发 PING 防止 NAT/空闲断链；PONG 行在监听循环里被忽略。
    _keepalive = Timer.periodic(const Duration(seconds: 25), (_) {
      final socket = _listenerSocket;
      if (socket != null) {
        try {
          socket.add('PING\n'.codeUnits);
          socket.flush();
        } catch (_) {}
      }
    });
    unawaited(_listenLoop());
  }

  Future<void> _listenLoop() async {
    var backoff = const Duration(seconds: 2);
    while (_running) {
      Socket? socket;
      StreamIterator<List<int>>? iterator;
      try {
        socket = await Socket.connect(
          defaultRelayHost,
          defaultRelayPort,
          timeout: const Duration(seconds: 10),
        );
        socket.add('LISTEN ${dataKey(selfId)}\n'.codeUnits);
        await socket.flush();
        _listenerSocket = socket;
        iterator = StreamIterator<List<int>>(socket);
        _listenerIterator = iterator;
        backoff = const Duration(seconds: 2);
        // 必须按行缓冲：TCP 可能把 `INCOMING …\n` 拆成多段，或与下一条粘连。
        final lines = LineBuffer();
        while (_running) {
          if (!await iterator.moveNext()) break;
          for (final text in lines.add(iterator.current)) {
            final trimmed = text.trim();
            if (trimmed.isEmpty || trimmed == 'PONG') continue;
            if (trimmed.startsWith('INCOMING ')) {
              await _openBridge(trimmed.substring('INCOMING '.length).trim());
            }
          }
        }
      } catch (_) {
        // 中继不可达或断线；退避后重试。
      } finally {
        _listenerSocket = null;
        _listenerIterator = null;
        try {
          await iterator?.cancel();
        } catch (_) {}
        if (socket != null) {
          unawaited(socket.close());
        }
      }
      if (!_running) return;
      await Future<void>.delayed(backoff);
      backoff = backoff * 2 > const Duration(seconds: 60)
          ? const Duration(seconds: 60)
          : backoff * 2;
    }
  }

  Future<void> _openBridge(String key) async {
    try {
      final socket = await Socket.connect(
        defaultRelayHost,
        defaultRelayPort,
        timeout: const Duration(seconds: 10),
      );
      socket.add('BRIDGE $key\n'.codeUnits);
      await socket.flush();
      await onIncomingConnection(socket);
    } catch (_) {
      // 桥接失败时中继会因拨号方超时清理房间。
    }
  }

  Future<void> stop() async {
    _running = false;
    _keepalive?.cancel();
    releaseHeldRooms();
    try {
      await _listenerIterator?.cancel();
    } catch (_) {}
    final socket = _listenerSocket;
    _listenerSocket = null;
    if (socket != null) {
      unawaited(socket.close());
    }
  }
}
