/// 聊天消息模型：聊天框是所有传输的统一入口，
/// 文字 / 图片 / 文件都以消息形式呈现并本地持久化。
enum ChatDirection { send, receive }

enum ChatKind { text, image, file }

enum ChatStatus {
  /// 已创建，等待传输引擎接管。
  pending,

  /// 传输中（进度见 transferId 对应的传输记录）。
  transferring,

  sent,

  received,

  failed,

  cancelled,
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.deviceId,
    required this.direction,
    required this.kind,
    required this.timestamp,
    this.textContent,
    this.fileName,
    this.filePath,
    this.size = 0,
    this.transferId,
    this.status = ChatStatus.pending,
    this.error,
    this.source,
  });

  final String id;

  /// 对端设备 id；聊天按设备分会话。
  final String deviceId;
  final ChatDirection direction;
  final ChatKind kind;
  final DateTime timestamp;

  /// 文字消息正文（仅本次运行内保留完整内容，持久化时截断超长文本）。
  final String? textContent;

  /// 文件 / 图片名。
  final String? fileName;

  /// 本地路径：发送→源文件；接收→保存位置。
  final String? filePath;
  final int size;

  /// 关联的传输记录 id（两端一致，用于同步进度与状态）。
  final String? transferId;
  final ChatStatus status;
  final String? error;

  /// 自动同步来源（剪贴板 / 下载目录），手动发送为 null。
  final String? source;

  bool get isImage => kind == ChatKind.image;

  bool get active =>
      status == ChatStatus.pending || status == ChatStatus.transferring;

  bool get finalized =>
      status == ChatStatus.sent ||
      status == ChatStatus.received ||
      status == ChatStatus.failed ||
      status == ChatStatus.cancelled;

  ChatMessage copyWith({
    String? textContent,
    String? filePath,
    int? size,
    String? transferId,
    ChatStatus? status,
    String? error,
    bool clearError = false,
  }) =>
      ChatMessage(
        id: id,
        deviceId: deviceId,
        direction: direction,
        kind: kind,
        timestamp: timestamp,
        textContent: textContent ?? this.textContent,
        fileName: fileName ?? this.fileName,
        filePath: filePath ?? this.filePath,
        size: size ?? this.size,
        transferId: transferId ?? this.transferId,
        status: status ?? this.status,
        error: clearError ? null : error ?? this.error,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'direction': direction.name,
        'kind': kind.name,
        'timestamp': timestamp.toIso8601String(),
        'textContent': textContent,
        'fileName': fileName,
        'filePath': filePath,
        'size': size,
        'transferId': transferId,
        'status': status.name,
        'error': error,
        'source': source,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        deviceId: json['deviceId'] as String,
        direction: ChatDirection.values.byName(json['direction'] as String),
        kind: ChatKind.values.byName(json['kind'] as String),
        timestamp: DateTime.parse(json['timestamp'] as String),
        textContent: json['textContent'] as String?,
        fileName: json['fileName'] as String?,
        filePath: json['filePath'] as String?,
        size: json['size'] as int? ?? 0,
        transferId: json['transferId'] as String?,
        status: ChatStatus.values.byName(json['status'] as String),
        error: json['error'] as String?,
        source: json['source'] as String?,
      );
}

/// 持久化时超长文本的截断上限（约 1 万字符），避免撑爆设置存储。
const chatPersistTextLimit = 10000;

/// 每个会话最多保留的消息条数。
const chatMaxMessagesPerDevice = 300;

/// 判断文件名是否按图片气泡展示（两端一致，无需改传输协议）。
bool chatKindIsImage(String fileName) {
  const extensions = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif',
  ];
  final lower = fileName.toLowerCase();
  return extensions.any(lower.endsWith);
}
