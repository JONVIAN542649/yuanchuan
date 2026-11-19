import 'dart:convert';
import 'dart:typed_data';

enum TransferDirection { sending, receiving }

enum TransferStatus {
  hashing,
  waiting,
  connecting,
  transferring,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

class TrustedDevice {
  const TrustedDevice({
    required this.id,
    required this.name,
    required this.publicKey,
    this.platform = 'unknown',
  });

  final String id;
  final String name;
  final String publicKey;

  /// 对端平台：android / ios / windows / macos / linux / unknown。
  final String platform;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'publicKey': publicKey,
        'platform': platform,
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> json) => TrustedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        publicKey: json['publicKey'] as String,
        platform: json['platform'] as String? ?? 'unknown',
      );

  TrustedDevice copyWith({String? name, String? platform}) => TrustedDevice(
        id: id,
        name: name ?? this.name,
        publicKey: publicKey,
        platform: platform ?? this.platform,
      );
}

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.device,
    required this.host,
    required this.port,
    required this.lastSeen,
  });

  final TrustedDevice device;
  final String host;
  final int port;
  final DateTime lastSeen;

  bool get online => DateTime.now().difference(lastSeen).inSeconds < 8;

  DiscoveredDevice copyWith({
    String? host,
    int? port,
    DateTime? lastSeen,
    String? name,
  }) =>
      DiscoveredDevice(
        device: device.copyWith(name: name),
        host: host ?? this.host,
        port: port ?? this.port,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

class TransferItem {
  const TransferItem({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.size,
    this.path,
    this.uri,
    this.data,
  });

  final String id;
  final String name;
  final String relativePath;
  final int size;
  final String? path;
  final String? uri;

  /// 文字消息的 UTF-8 字节。仅本次运行内保留，不写入历史设置。
  final Uint8List? data;

  bool get isText => data != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'relativePath': relativePath,
        'size': size,
        'path': path,
        'uri': uri,
        'isText': isText,
      };

  factory TransferItem.fromJson(Map<String, dynamic> json) => TransferItem(
        id: json['id'] as String,
        name: json['name'] as String,
        relativePath: json['relativePath'] as String,
        size: json['size'] as int,
        path: json['path'] as String?,
        uri: json['uri'] as String?,
      );
}

class TransferRecord {
  const TransferRecord({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.direction,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.bytesTransferred = 0,
    this.sha256 = '',
    this.error,
    this.savePath,
    this.item,
    this.isText = false,
    this.textContent,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final String name;
  final String relativePath;
  final int size;
  final int bytesTransferred;
  final String sha256;
  final TransferDirection direction;
  final TransferStatus status;
  final String? error;
  final String? savePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TransferItem? item;

  /// 文字消息标记；正文只在本次运行内保留，避免超长内容撑爆设置存储。
  final bool isText;
  final String? textContent;

  bool get isTextRecord => isText || item?.isText == true;

  double get progress => size == 0 ? 1 : bytesTransferred / size;
  bool get active =>
      status == TransferStatus.hashing ||
      status == TransferStatus.waiting ||
      status == TransferStatus.connecting ||
      status == TransferStatus.transferring ||
      status == TransferStatus.verifying;

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'name': name,
        'relativePath': relativePath,
        'size': size,
        'bytesTransferred': bytesTransferred,
        'sha256': sha256,
        'direction': direction.name,
        'status': status.name,
        'error': error,
        'savePath': savePath,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'item': item?.toJson(),
        'isText': isText,
      };

  String encode() => jsonEncode(toJson());

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
        id: json['id'] as String,
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        name: json['name'] as String,
        relativePath: json['relativePath'] as String,
        size: json['size'] as int,
        bytesTransferred: json['bytesTransferred'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
        direction: TransferDirection.values.byName(json['direction'] as String),
        status: TransferStatus.values.byName(json['status'] as String),
        error: json['error'] as String?,
        savePath: json['savePath'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        item: json['item'] == null
            ? null
            : TransferItem.fromJson(json['item'] as Map<String, dynamic>),
        isText: json['isText'] as bool? ?? false,
      );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var index = -1;
  do {
    value /= 1024;
    index++;
  } while (value >= 1024 && index < units.length - 1);
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[index]}';
}

/// 一个待确认的接收请求预览：接收前询问弹窗与横幅共用。
class IncomingOffer {
  const IncomingOffer({
    required this.name,
    required this.size,
    required this.isText,
    required this.peerName,
  });

  final String name;
  final int size;
  final bool isText;
  final String peerName;

  String get summary => isText ? '一条文字消息' : '${formatBytes(size)} 的「$name」';
}

String transferStatusText(TransferStatus status) => switch (status) {
      TransferStatus.hashing => '正在计算校验',
      TransferStatus.waiting => '等待连接',
      TransferStatus.connecting => '正在连接',
      TransferStatus.transferring => '正在传输',
      TransferStatus.paused => '已暂停',
      TransferStatus.verifying => '正在校验',
      TransferStatus.completed => '已完成',
      TransferStatus.failed => '失败，可续传',
      TransferStatus.cancelled => '已取消',
    };
