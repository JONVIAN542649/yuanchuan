import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer_models.dart';

/// 传输历史持久化：独立 JSON 文件 + 防抖写入，避免每秒刷 SharedPreferences。
class TransferHistoryStore {
  TransferHistoryStore({
    this.fileName = 'transfer_history.json',
    this.debounce = const Duration(seconds: 3),
    Directory? overrideDirectory,
  }) : _overrideDirectory = overrideDirectory;

  static const legacyPrefsKey = 'local_file_drop.transfer_history';

  final String fileName;
  final Duration debounce;
  final Directory? _overrideDirectory;

  File? _file;
  Timer? _debounce;
  bool _dirty = false;
  List<TransferRecord> _records = [];

  List<TransferRecord> get records => List.unmodifiable(_records);

  Future<File> _resolveFile() async {
    if (_file != null) return _file!;
    Directory dir;
    if (_overrideDirectory != null) {
      dir = _overrideDirectory;
    } else {
      try {
        dir = await getApplicationSupportDirectory();
      } catch (_) {
        // 单元测试等无 path_provider 插件的环境：每实例独立临时目录，避免串台。
        dir = await Directory.systemTemp.createTemp('yc_hist_');
      }
    }
    await dir.create(recursive: true);
    _file = File(p.join(dir.path, fileName));
    return _file!;
  }

  Future<List<TransferRecord>> load() async {
    final file = await _resolveFile();
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _records = [
          for (final value in list)
            TransferRecord.fromJson(value as Map<String, dynamic>),
        ];
        return records;
      } catch (_) {
        // 损坏文件不影响启动，继续尝试迁移旧偏好。
      }
    }
    // 兼容：从 SharedPreferences 迁移一次后清除旧键。
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(legacyPrefsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        _records = [
          for (final value in list)
            TransferRecord.fromJson(value as Map<String, dynamic>),
        ];
        await file.writeAsString(
          jsonEncode(_records.map((r) => r.toJson()).toList()),
        );
        await preferences.remove(legacyPrefsKey);
      }
    } catch (_) {}
    return records;
  }

  /// 用最新列表替换内存快照，并安排防抖落盘。
  void scheduleSave(List<TransferRecord> records) {
    _records = List.of(records);
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    if (!_dirty) return;
    _dirty = false;
    final snapshot = jsonEncode(_records.map((r) => r.toJson()).toList());
    final file = await _resolveFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(snapshot);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await tmp.rename(file.path);
  }

  Future<void> close() async {
    await flush();
  }
}
