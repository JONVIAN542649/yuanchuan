import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_models.dart';
import '../models/transfer_models.dart';
import 'chat_store.dart';
import 'content_hash.dart';
import 'identity_service.dart';
import 'platform_gateway.dart';
import 'stable_file.dart';

/// 手机 → 电脑自动同步（需求 4）：
/// - 剪贴板文字：应用前台时轮询系统剪贴板（Android 10+ 只允许前台读取，
///   这本身就是系统上限，锁屏/后台由系统拦截）；
/// - 下载目录新图片/新文件：原生 FileObserver（TransferService 内）
///   经 platform channel 推送路径到 [handleNativeDownload]。
///
/// 统一约束：去抖去重（同一内容只发一次，记录持久化）、逐项开关
/// （默认文字开/图片开/文件关）、仅配对设备在线时发送，离线进积压队列
/// （上限 [maxBacklog]，重连后按序补传），消息带来源标注进聊天框。
class AutoSyncService with WidgetsBindingObserver {
  AutoSyncService({
    required this.chatStore,
    required this.gateway,
    required this.devices,
    required this.onlineDevices,
    this.waitForStableFile = waitUntilFileStable,
  });

  static const _channel = MethodChannel('local_file_drop/system');
  static const _kClipboard = 'local_file_drop.sync.clipboard';
  static const _kImages = 'local_file_drop.sync.images';
  static const _kFiles = 'local_file_drop.sync.files';
  static const _kLastClipboardHash = 'local_file_drop.sync.last_clipboard_hash';
  static const _kSeen = 'local_file_drop.sync.seen';
  static const _kBacklog = 'local_file_drop.sync.backlog';
  static const _kTargetDevice = 'local_file_drop.sync.target_device';
  // 旧键：曾明文存剪贴板，加载后立即清除。
  static const _kLegacyClipboard = 'local_file_drop.sync.last_clipboard';

  /// 下载积压上限：超出后丢弃最旧的（防失控占内存）。
  static const maxBacklog = 50;

  /// 剪贴板轮询间隔。
  static const clipboardPollInterval = Duration(milliseconds: 2500);

  final ChatStore chatStore;
  final PlatformGateway gateway;
  final List<DiscoveredDevice> Function() devices;
  final List<DiscoveredDevice> Function() onlineDevices;
  final Future<int> Function(File file) waitForStableFile;

  bool clipboardEnabled = true;
  bool imagesEnabled = true;
  bool filesEnabled = false;

  /// 用户指定的默认同步目标设备 id；null 表示尚未选择。
  String? preferredTargetId;

  Timer? _pollTimer;
  String? _lastSentClipboardHash;
  List<String> _seenKeys = [];
  List<Map<String, dynamic>> _backlog = [];
  bool _loaded = false;
  bool _flushing = false;
  SharedPreferences? _preferences;

  /// 测试/诊断用：最近一次剪贴板内容哈希（不含明文）。
  String? get lastSentClipboardHash => _lastSentClipboardHash;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    _preferences = preferences;
    clipboardEnabled = preferences.getBool(_kClipboard) ?? true;
    imagesEnabled = preferences.getBool(_kImages) ?? true;
    filesEnabled = preferences.getBool(_kFiles) ?? false;
    preferredTargetId = preferences.getString(_kTargetDevice);
    _lastSentClipboardHash = preferences.getString(_kLastClipboardHash);
    // 迁移：旧版明文剪贴板只保留哈希后立刻删除明文。
    final legacy = preferences.getString(_kLegacyClipboard);
    if (legacy != null) {
      _lastSentClipboardHash ??= contentHash(legacy);
      await preferences.setString(_kLastClipboardHash, _lastSentClipboardHash!);
      await preferences.remove(_kLegacyClipboard);
    }
    _seenKeys = List<String>.from(
        preferences.getStringList(_kSeen) ?? const <String>[]);
    // 迁移旧的 hashCode 去重键：无法可靠换算，清空以免误伤；内容哈希会重建。
    _seenKeys = [
      for (final key in _seenKeys)
        if (!key.startsWith('t:') || key.length > 20) key,
    ];
    if (_seenKeys.length > 400) _seenKeys = _seenKeys.sublist(200);
    final rawBacklog = preferences.getStringList(_kBacklog) ?? const [];
    _backlog = [
      for (final item in rawBacklog) jsonDecode(item) as Map<String, dynamic>,
    ];
    _loaded = true;
    if (gateway.isAndroid) {
      _channel.setMethodCallHandler(_onNativeCall);
    }
  }

  /// 开始前台工作：注册生命周期监听 + 剪贴板轮询。
  void start() {
    if (!gateway.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    _pollTimer = Timer.periodic(clipboardPollInterval, (_) => _pollClipboard());
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只在前台轮询；回到前台立即查一次（把切走期间复制的文字带上）。
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollClipboard());
    }
  }

  Future<void> setClipboardEnabled(bool value) async {
    clipboardEnabled = value;
    await _preferences?.setBool(_kClipboard, value);
  }

  Future<void> setImagesEnabled(bool value) async {
    imagesEnabled = value;
    await _preferences?.setBool(_kImages, value);
  }

  Future<void> setFilesEnabled(bool value) async {
    filesEnabled = value;
    await _preferences?.setBool(_kFiles, value);
  }

  /// 设定默认同步目标；空字符串表示清除（回退为“仅一台在线时自动选”）。
  Future<void> setPreferredTargetId(String? deviceId) async {
    preferredTargetId =
        (deviceId == null || deviceId.isEmpty) ? null : deviceId;
    if (preferredTargetId == null) {
      await _preferences?.remove(_kTargetDevice);
    } else {
      await _preferences?.setString(_kTargetDevice, preferredTargetId!);
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'onDownloaded' && call.arguments is Map) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final path = args['path'] as String? ?? '';
      final size = (args['size'] as num?)?.toInt() ?? 0;
      if (path.isNotEmpty) {
        await handleNativeDownload(path, size);
      }
    }
  }

  /// 原生 FileObserver 推来的下载目录新文件。
  Future<void> handleNativeDownload(String path, int size) async {
    if (!_loaded) return;
    final file = File(path);
    int stableSize;
    try {
      stableSize = await waitForStableFile(file);
    } catch (_) {
      // 写完超时或文件消失：跳过，避免传半截。
      return;
    }
    final key = syncKeyFor(path, stableSize);
    if (_seenKeys.contains(key)) return;
    final isImage = chatKindIsImage(path);
    if (isImage ? !imagesEnabled : !filesEnabled) return;
    await _seenMarked(key);
    await _syncOrQueue(path: path, size: stableSize, isImage: isImage);
  }

  /// 剪贴板轮询：内容变化且不为空时按文字消息同步。
  Future<void> _pollClipboard() async {
    if (!_loaded || !clipboardEnabled) return;
    if (onlineDevices().isEmpty) return;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null || text.trim().isEmpty) return;
      await syncClipboardText(text);
    } catch (_) {
      // 某些系统剪贴板读取失败，静默跳过本轮。
    }
  }

  /// 剪贴板同步入口（轮询与测试共用）；同一内容只发一次。
  Future<bool> syncClipboardText(String text) async {
    if (!_loaded || !clipboardEnabled) return false;
    final hash = contentHash(text);
    if (hash == _lastSentClipboardHash) return false;
    if (_seenKeys.contains(clipboardDedupKey(text))) return false;
    final target = _targetDevice();
    if (target == null) return false;
    await _seenMarked(clipboardDedupKey(text));
    _lastSentClipboardHash = hash;
    await _preferences?.setString(_kLastClipboardHash, hash);
    await _preferences?.remove(_kLegacyClipboard);
    await chatStore.sendText(target, text, source: '剪贴板');
    return true;
  }

  /// 发送或进积压队列；在线设备存在时按序补传积压。
  Future<void> _syncOrQueue({
    required String path,
    required int size,
    required bool isImage,
  }) async {
    _backlog.add({
      'path': path,
      'size': size,
      'isImage': isImage,
      'at': DateTime.now().toIso8601String(),
    });
    while (_backlog.length > maxBacklog) {
      _backlog.removeAt(0);
    }
    await _saveBacklog();
    await flushBacklog();
  }

  /// 断连积压 → 重连后补传（由 AppState 在设备变化时触发）。
  Future<void> flushBacklog() async {
    if (_flushing || !_loaded || _backlog.isEmpty) return;
    final target = _targetDevice();
    if (target == null) return;
    _flushing = true;
    try {
      while (_backlog.isNotEmpty) {
        if (_targetDevice() == null) return;
        final entry = _backlog.first;
        final path = entry['path'] as String;
        final file = File(path);
        if (!file.existsSync()) {
          _backlog.removeAt(0);
          await _saveBacklog();
          continue;
        }
        await chatStore.sendFiles(
          target,
          [
            TransferItem(
              id: randomId(),
              name: p.basename(path),
              relativePath: p.basename(path),
              size: file.lengthSync(),
              path: path,
            ),
          ],
          source: '下载目录',
        );
        _backlog.removeAt(0);
        await _saveBacklog();
      }
    } finally {
      _flushing = false;
    }
  }

  /// 测试/诊断用：当前积压长度。
  int get backlogLength => _backlog.length;

  /// 自动同步目标：优先用户指定且在线的设备；否则仅当恰好一台在线时使用它。
  DiscoveredDevice? _targetDevice() {
    final online = onlineDevices();
    if (online.isEmpty) return null;
    final preferred = preferredTargetId;
    if (preferred != null) {
      for (final device in online) {
        if (device.device.id == preferred) return device;
      }
      // 指定目标不在线：不误发到其他电脑。
      return null;
    }
    if (online.length == 1) return online.first;
    return null;
  }

  Future<void> _seenMarked(String key) async {
    _seenKeys.add(key);
    if (_seenKeys.length > 400) _seenKeys = _seenKeys.sublist(200);
    await _preferences?.setStringList(_kSeen, _seenKeys);
  }

  Future<void> _saveBacklog() async {
    await _preferences?.setStringList(
      _kBacklog,
      [for (final item in _backlog) jsonEncode(item)],
    );
  }

  /// 去重键：路径 + 大小 + 修改时间（同一路径重写内容视为新文件）。
  static String syncKeyFor(String path, int size) {
    final mtime = File(path).existsSync()
        ? File(path).lastModifiedSync().millisecondsSinceEpoch
        : 0;
    return 'f:$path:$size:$mtime';
  }

  static String syncKeyForText(String text) => clipboardDedupKey(text);
}
