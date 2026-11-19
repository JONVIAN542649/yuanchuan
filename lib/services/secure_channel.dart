import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_pool.dart';
import 'identity_service.dart';

const _maxHandshakeBytes = 64 * 1024;
// 加密帧上限：需容纳 1 MiB 分块 + 头部 + AES-GCM 随机数与认证标签。
const _maxFrameBytes = 3 * 1024 * 1024;

/// 连续读缓冲：避免旧实现每次 `List.addAll` + `removeRange` 的 O(n) 拷贝。
///
/// 策略：把 socket 块追加进可增长的 [Uint8List]，用读指针消费；
/// 当已消费超过一半容量时把剩余字节搬到开头，保持缓冲紧凑。
class SocketReader {
  SocketReader(Socket socket) : _iterator = StreamIterator<List<int>>(socket);

  final StreamIterator<List<int>> _iterator;
  Uint8List _buffer = Uint8List(0);
  var _start = 0;
  var _end = 0;

  int get _length => _end - _start;

  Future<Uint8List> readBytes(int length) async {
    if (length < 0) throw ArgumentError.value(length, 'length');
    while (_length < length) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('连接已关闭');
      }
      _append(_iterator.current);
    }
    final result = Uint8List(length);
    result.setRange(0, length, _buffer, _start);
    _start += length;
    _compactIfNeeded();
    return result;
  }

  void _append(List<int> chunk) {
    if (chunk.isEmpty) return;
    final needed = _length + chunk.length;
    if (_buffer.length - _end < chunk.length) {
      // 空间不足：搬到新缓冲或紧凑后扩容。
      final grown = Uint8List(_capacityFor(needed));
      if (_length > 0) {
        grown.setRange(0, _length, _buffer, _start);
      }
      _buffer = grown;
      _end = _length;
      _start = 0;
    }
    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  int _capacityFor(int needed) {
    var capacity = _buffer.isEmpty ? 4096 : _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    return capacity;
  }

  void _compactIfNeeded() {
    if (_start == 0) return;
    // 已消费超过一半，或读指针过大时紧凑，避免缓冲无限右移。
    if (_start >= 64 * 1024 || _start * 2 >= _buffer.length) {
      final remain = _length;
      if (remain == 0) {
        _start = 0;
        _end = 0;
        return;
      }
      final compacted = Uint8List(_capacityFor(remain));
      compacted.setRange(0, remain, _buffer, _start);
      _buffer = compacted;
      _start = 0;
      _end = remain;
    }
  }

  Future<void> close() => _iterator.cancel();
}

Future<void> writePlainJson(Socket socket, Map<String, dynamic> value) async {
  final bytes = utf8.encode(jsonEncode(value));
  final output = BytesBuilder();
  output.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
  output.add(bytes);
  socket.add(output.takeBytes());
  await socket.flush();
}

Future<Map<String, dynamic>> readPlainJson(SocketReader reader) async {
  final length = (await reader.readBytes(4)).buffer.asByteData().getUint32(0);
  if (length == 0 || length > _maxHandshakeBytes) {
    throw const SocketException('非法握手数据');
  }
  final bytes = await reader.readBytes(length);
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

class SecureMessage {
  const SecureMessage(this.header, this.payload);

  final Map<String, dynamic> header;
  final Uint8List payload;

  String get type => header['type'] as String;
}

class HelloMessage {
  const HelloMessage({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.nonce,
    this.pairingToken,
  });

  final String deviceId;
  final String name;
  final List<int> publicKey;
  final List<int> nonce;
  final String? pairingToken;

  factory HelloMessage.fromJson(Map<String, dynamic> json) => HelloMessage(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        publicKey: base64Decode(json['publicKey'] as String),
        nonce: base64Decode(json['nonce'] as String),
        pairingToken: json['pairingToken'] as String?,
      );
}

class SecureChannel {
  SecureChannel._(
    this.socket,
    this._reader,
    this._secretKey,
    this._keyBytes,
    this.peerId,
    this.peerName,
    this.peerPublicKey,
  );

  final Socket socket;
  final SocketReader _reader;
  final SecretKey _secretKey;
  final Uint8List _keyBytes;
  final String peerId;
  final String peerName;
  final Uint8List peerPublicKey;
  final _aes = AesGcm.with256bits();

  /// 串行化所有写出，避免发送流水线与 pause/cancel 并发写导致密文帧交错损坏。
  Future<void> _writeChain = Future<void>.value();

  Future<T> _serializedWrite<T>(Future<T> Function() action) {
    final next = _writeChain.catchError((_) {}).then((_) => action());
    _writeChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// 大帧加解密共用一个 isolate 池；小帧（JSON/ack）留在主 isolate 走低延迟路径。
  static CryptoPool? _poolOverride;
  static CryptoPool get cryptoPool => _poolOverride ??= CryptoPool(workers: 4);
  static set cryptoPool(CryptoPool? pool) {
    _poolOverride?.dispose();
    _poolOverride = pool;
  }

  static const _poolThreshold = 128 * 1024;

  /// 会话对称密钥字节（供加密池 worker 使用）。
  Uint8List get keyBytes => _keyBytes;

  /// 发送端流水线把已加密帧排队后统一落 socket。
  ///
  /// [flush] 默认 false：流水线窗口未满时只写入内核缓冲，避免每块一次 flush
  /// 把吞吐钉在 RTT 上；窗口打满或文件尾再 [flushSocket]。
  Future<void> sendRawFrame(Uint8List cipherFrame, {bool flush = false}) {
    return _serializedWrite(() async {
      socket.add(
          (ByteData(4)..setUint32(0, cipherFrame.length)).buffer.asUint8List());
      socket.add(cipherFrame);
      if (flush) await socket.flush();
    });
  }

  /// 主动刷出已排队的密文帧（流水线窗口满 / 文件尾）。
  Future<void> flushSocket() => _serializedWrite(() => socket.flush());

  /// 读取一个原始密文帧（不含 4 字节长度前缀），供解密流水线预读。
  Future<Uint8List> readRawFrame() async {
    final length =
        (await _reader.readBytes(4)).buffer.asByteData().getUint32(0);
    if (length < 28 || length > _maxFrameBytes) {
      throw const SocketException('非法加密数据帧');
    }
    return await _reader.readBytes(length);
  }

  /// 解密原始帧（大帧走 isolate 池）。
  Future<SecureMessage> decryptRaw(Uint8List frame) async {
    final Uint8List plain;
    if (frame.length >= _poolThreshold) {
      plain = await cryptoPool.decryptFrame(frame, _keyBytes);
    } else {
      final nonce = frame.sublist(0, 12);
      final mac = frame.sublist(frame.length - 16);
      final cipherText = frame.sublist(12, frame.length - 16);
      plain = Uint8List.fromList(await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: _secretKey,
      ));
    }
    final parsed = parsePlainFrame(plain);
    return SecureMessage(parsed.header, parsed.payload);
  }

  static Future<SecureChannel> connect(
    Socket socket, {
    required DeviceIdentity identity,
    String? pairingToken,
    String? expectedDeviceId,
    List<int>? expectedPublicKey,
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    final reader = SocketReader(socket);
    final clientNonce = randomBytes(32);
    await writePlainJson(socket, {
      'type': 'hello',
      'version': 1,
      'deviceId': identity.id,
      'name': identity.name,
      'publicKey': identity.publicKeyBase64,
      'nonce': base64Encode(clientNonce),
      if (pairingToken != null) 'pairingToken': pairingToken,
    });
    final response = await readPlainJson(reader).timeout(
      handshakeTimeout,
      onTimeout: () => throw const SocketException(
        '配对握手超时：请确认电脑端已打开“显示配对码”且仍在 5 分钟有效期内',
      ),
    );
    if (response['type'] == 'error') {
      throw SocketException(response['message'] as String? ?? '对方拒绝连接');
    }
    if (response['type'] != 'helloAck') {
      throw const SocketException('握手响应无效');
    }
    final peerId = response['deviceId'] as String;
    final peerPublicKey = base64Decode(response['publicKey'] as String);
    if (expectedDeviceId != null && expectedDeviceId != peerId) {
      throw const SocketException('设备身份与配对记录不符');
    }
    if (expectedPublicKey != null &&
        !const ListEquality<int>().equals(expectedPublicKey, peerPublicKey)) {
      throw const SocketException('设备密钥已变化，已阻止连接');
    }
    final serverNonce = base64Decode(response['nonce'] as String);
    final key = await _deriveKey(
      identity: identity,
      remotePublicKey: peerPublicKey,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      clientId: identity.id,
      serverId: peerId,
    );
    // 关闭 Nagle：小帧（chunkAck/控制消息）必须即时发出，
    // 否则 Nagle×延迟 ACK 会把流水线每块卡掉 200-400ms。
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SecureChannel._(
      socket,
      reader,
      key,
      Uint8List.fromList(await key.extractBytes()),
      peerId,
      response['name'] as String? ?? peerId,
      Uint8List.fromList(peerPublicKey),
    );
  }

  static Future<SecureChannel> accept(
    Socket socket, {
    required DeviceIdentity identity,
    required Future<bool> Function(HelloMessage hello) authorize,
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = SocketReader(socket);
    final request = await readPlainJson(reader).timeout(
      handshakeTimeout,
      onTimeout: () => throw const SocketException('握手请求超时'),
    );
    if (request['type'] != 'hello' || request['version'] != 1) {
      throw const SocketException('不支持的握手协议');
    }
    final hello = HelloMessage.fromJson(request);
    if (!await authorize(hello)) {
      await writePlainJson(socket, {
        'type': 'error',
        'message': '设备未配对或配对码已失效',
      });
      throw const SocketException('设备未配对');
    }
    final serverNonce = randomBytes(32);
    await writePlainJson(socket, {
      'type': 'helloAck',
      'deviceId': identity.id,
      'name': identity.name,
      'publicKey': identity.publicKeyBase64,
      'nonce': base64Encode(serverNonce),
    });
    final key = await _deriveKey(
      identity: identity,
      remotePublicKey: hello.publicKey,
      clientNonce: hello.nonce,
      serverNonce: serverNonce,
      clientId: hello.deviceId,
      serverId: identity.id,
    );
    return SecureChannel._(
      socket,
      reader,
      key,
      Uint8List.fromList(await key.extractBytes()),
      hello.deviceId,
      hello.name,
      Uint8List.fromList(hello.publicKey),
    );
  }

  static Future<SecretKey> _deriveKey({
    required DeviceIdentity identity,
    required List<int> remotePublicKey,
    required List<int> clientNonce,
    required List<int> serverNonce,
    required String clientId,
    required String serverId,
  }) async {
    final shared = await identity.sharedSecret(remotePublicKey);
    final ids = [clientId, serverId]..sort();
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: [...clientNonce, ...serverNonce],
      info: utf8.encode('LocalFileDrop/v1/${ids[0]}/${ids[1]}'),
    );
  }

  Future<void> sendJson(String type, [Map<String, dynamic> data = const {}]) {
    return sendMessage(type, data, Uint8List(0));
  }

  Future<void> sendMessage(
    String type,
    Map<String, dynamic> data,
    Uint8List payload,
  ) async {
    final header = utf8.encode(jsonEncode({'type': type, ...data}));
    final body = BytesBuilder();
    body.add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List());
    body.add(header);
    body.add(payload);
    final plainFrame = body.takeBytes();
    if (payload.length >= _poolThreshold) {
      // 大帧（分块）交给 isolate 池加密，主 isolate 不被 1MiB 加密阻塞。
      final cipher = await cryptoPool.encryptFrame(plainFrame, _keyBytes);
      await sendRawFrame(cipher, flush: true);
      return;
    }
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(
      plainFrame,
      secretKey: _secretKey,
      nonce: nonce,
    );
    final frame = BytesBuilder();
    final encryptedLength = 12 + box.cipherText.length + box.mac.bytes.length;
    frame
        .add((ByteData(4)..setUint32(0, encryptedLength)).buffer.asUint8List());
    frame.add(nonce);
    frame.add(box.cipherText);
    frame.add(box.mac.bytes);
    final bytes = frame.takeBytes();
    await _serializedWrite(() async {
      socket.add(bytes);
      await socket.flush();
    });
  }

  Future<SecureMessage> read() async {
    return decryptRaw(await readRawFrame());
  }

  bool _closed = false;

  /// 幂等关闭：队列收尾与 manager.close 可能并发触发同一通道的关闭。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _reader.close();
    } catch (_) {}
    try {
      await socket.close();
    } catch (_) {}
  }
}
