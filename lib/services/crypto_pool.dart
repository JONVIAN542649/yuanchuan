import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 纯 Dart AES-GCM 单核只有 ~7MB/s（1MiB 加密 ~147ms），是传输吞吐的硬上限。
/// 这里把大帧的加解密搬进常驻 isolate 池并行执行，配合传输层流水线，
/// 回环吞吐可从 2.4 MB/s 提升到线速；不新增任何第三方依赖。
///
/// ## 为何本轮仍未切换 Windows CNG / Android 硬件 AES
/// - 线协议固定为 X25519 + HKDF-SHA256 + AES-GCM（12B nonce + 16B tag），
///   Windows/Android 两端必须字节级互通；原生实现若 nonce/tag 布局或
///   填充细节有偏差，会静默破坏跨平台传输。
/// - Flutter 侧已有 `cryptography` + isolate 池，再引入 FFI/插件会牵动
///   Windows CMake 与 Android Gradle，个人工具发版成本高、回归面大。
/// - 本轮优先落地：批量 flush、连续读缓冲、接收端流式哈希、路径竞速等
///   不改密码学语义的吞吐优化；原生 AES 待单独专项（对齐向量 + 双端 CI）
///   后再切换，可保持协议不变地替换本池的 worker 实现。
///
/// 帧格式与 SecureChannel 完全一致：
/// 明文帧 = [4B 头长度][JSON 头][payload]；密文帧 = [12B nonce][cipherText][16B mac]。
class CryptoPool {
  CryptoPool({int workers = 4}) {
    for (var slot = 0; slot < workers; slot++) {
      _slots.add(null);
      _ready.add(_spawn().then((worker) {
        _slots[slot] = worker;
        return worker;
      }));
    }
  }

  static const _tagEncrypt = 1;
  static const _tagDecrypt = 2;
  static const _tagResult = 3;
  static const _tagError = 4;

  final List<Future<_Worker>> _ready = [];
  final List<_Worker?> _slots = [];
  var _next = 0;

  /// 槽位轮询：并行任务真正分散到所有 worker（否则只会用第一个）。
  Future<_Worker> _available() async {
    final slot = _next++ % _slots.length;
    final worker = _slots[slot];
    if (worker != null) return worker;
    return _ready[slot];
  }

  Future<_Worker> _spawn() async {
    final replyPort = ReceivePort();
    final ready = Completer<SendPort>();
    final worker = _Worker(replyPort, ready);
    await Isolate.spawn(_workerMain, replyPort.sendPort);
    await ready.future;
    return worker;
  }

  /// 加密一个明文帧，返回 [12B nonce|cipherText|16B mac] 密文帧。
  /// nonce 由主 isolate 用安全随机生成（GCM 同密钥下 nonce 绝不可复用）。
  Future<Uint8List> encryptFrame(
    Uint8List plainFrame,
    Uint8List keyBytes,
  ) async {
    final worker = await _available();
    final nonce = secureNonce();
    final transferable = TransferableTypedData.fromList([plainFrame]);
    final completer = Completer<Uint8List>();
    worker.pending[worker.nextId] = completer;
    worker.sendPort
        .send((_tagEncrypt, worker.nextId++, transferable, keyBytes, nonce));
    return completer.future;
  }

  /// 解密 [12B nonce|cipherText|16B mac] 帧，返回明文帧字节。
  Future<Uint8List> decryptFrame(
    Uint8List frame,
    Uint8List keyBytes,
  ) async {
    final worker = await _available();
    final transferable = TransferableTypedData.fromList([frame]);
    final completer = Completer<Uint8List>();
    worker.pending[worker.nextId] = completer;
    worker.sendPort
        .send((_tagDecrypt, worker.nextId++, transferable, keyBytes, null));
    return completer.future;
  }

  Future<void> dispose() async {
    for (final worker in _slots) {
      worker?.receivePort.close();
    }
    _slots.clear();
    _ready.clear();
  }

  /// worker 主循环：每个 isolate 独立持有 AesGcm 实例。
  static Future<void> _workerMain(SendPort reply) async {
    final inbound = ReceivePort();
    final aes = AesGcm.with256bits();
    reply.send(inbound.sendPort);
    await for (final message in inbound) {
      final (tag, id, transferable, keyBytes, nonce) =
          message as (int, int, TransferableTypedData, Uint8List, Uint8List?);
      try {
        final data = transferable.materialize().asUint8List();
        final key = SecretKey(keyBytes);
        final Uint8List result;
        if (tag == _tagEncrypt) {
          final box = await aes.encrypt(data, secretKey: key, nonce: nonce!);
          final frame = BytesBuilder()
            ..add(nonce)
            ..add(box.cipherText)
            ..add(box.mac.bytes);
          result = frame.takeBytes();
        } else {
          final actualNonce = data.sublist(0, 12);
          final mac = data.sublist(data.length - 16);
          final cipher = data.sublist(12, data.length - 16);
          final plain = await aes.decrypt(
            SecretBox(cipher, nonce: actualNonce, mac: Mac(mac)),
            secretKey: key,
          );
          result = Uint8List.fromList(plain);
        }
        reply.send((_tagResult, id, TransferableTypedData.fromList([result])));
      } catch (error) {
        reply.send((_tagError, id, '$error'));
      }
    }
  }
}

/// GCM nonce（12 字节，安全随机）。
Uint8List secureNonce() {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(12, (_) => random.nextInt(256)));
}

class _Worker {
  _Worker(this.receivePort, this.ready) {
    receivePort.listen((message) {
      // 第一条消息是 worker 的回执端口；其余为任务结果。
      if (message is SendPort) {
        sendPort = message;
        ready.complete(message);
        return;
      }
      final (tag, id, payload) = message as (int, int, Object);
      final completer = pending.remove(id);
      if (completer == null) return;
      if (tag == CryptoPool._tagResult) {
        completer.complete(
            (payload as TransferableTypedData).materialize().asUint8List());
      } else {
        completer.completeError(StateError('$payload'));
      }
    });
  }

  final ReceivePort receivePort;
  final Completer<SendPort> ready;
  late SendPort sendPort;
  final Map<int, Completer<Uint8List>> pending = {};
  var nextId = 0;
}

/// 组装明文帧：[4B 头长度][JSON 头][payload]，与 SecureChannel.sendMessage 一致。
Uint8List buildPlainFrame(Map<String, dynamic> header, Uint8List payload) {
  final headerBytes = utf8.encode(jsonEncode(header));
  final body = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, headerBytes.length)).buffer.asUint8List());
  body.add(headerBytes);
  body.add(payload);
  return body.takeBytes();
}

/// 从明文帧解析头与 payload，与 SecureChannel.read 一致。
/// payload 是原缓冲区的视图（零拷贝），调用方用完前不得丢弃缓冲区。
({Map<String, dynamic> header, Uint8List payload}) parsePlainFrame(
  Uint8List plain,
) {
  final headerLength = ByteData.sublistView(plain).getUint32(0);
  if (headerLength > plain.length - 4) {
    throw const FormatException('加密数据头无效');
  }
  final header = jsonDecode(utf8.decode(plain.sublist(4, 4 + headerLength)))
      as Map<String, dynamic>;
  final payload = plain.length > 4 + headerLength
      ? Uint8List.sublistView(plain, 4 + headerLength)
      : Uint8List(0);
  return (header: header, payload: payload);
}
