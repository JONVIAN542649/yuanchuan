import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/transfer_models.dart';
import 'identity_service.dart';

/// 传输分块大小。1 MiB 对局域网与中继都合适：配合 8 深流水线，
/// 在 50ms RTT 的中继链路上理论吞吐仍有约 160MB/s 余量。
const transferChunkSize = 1024 * 1024;

class PlatformGateway {
  static const _channel = MethodChannel('local_file_drop/system');

  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  Future<List<TransferItem>> pickFiles() async {
    if (isAndroid) {
      final result = await _channel.invokeListMethod<dynamic>('pickFiles');
      return _androidItems(result);
    }
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.any,
    );
    if (result == null) return [];
    return [
      for (final file in result.files)
        if (file.path != null)
          TransferItem(
            id: randomId(),
            name: file.name,
            relativePath: file.name,
            size: file.size,
            path: file.path,
          ),
    ];
  }

  Future<List<TransferItem>> pickImages() async {
    if (isAndroid) {
      final result = await _channel.invokeListMethod<dynamic>('pickImages');
      return _androidItems(result);
    }
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.image,
    );
    if (result == null) return [];
    return [
      for (final file in result.files)
        if (file.path != null)
          TransferItem(
            id: randomId(),
            name: file.name,
            relativePath: file.name,
            size: file.size,
            path: file.path,
          ),
    ];
  }

  Future<List<TransferItem>> pickFolder() async {
    if (isAndroid) {
      final result = await _channel.invokeListMethod<dynamic>('pickFolder');
      return _androidItems(result);
    }
    final selected = await FilePicker.platform.getDirectoryPath();
    if (selected == null) return [];
    final rootName = p.basename(selected);
    final entities = await Directory(selected).list(recursive: true).toList();
    final files = entities.whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        TransferItem(
          id: randomId(),
          name: p.basename(file.path),
          relativePath: p.join(rootName, p.relative(file.path, from: selected)),
          size: await file.length(),
          path: file.path,
        ),
    ];
  }

  List<TransferItem> _androidItems(List<dynamic>? result) {
    if (result == null) return [];
    return result.map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      return TransferItem(
        id: randomId(),
        name: map['name'] as String,
        relativePath: map['relativePath'] as String? ?? map['name'] as String,
        size: (map['size'] as num).toInt(),
        uri: map['uri'] as String,
      );
    }).toList();
  }

  /// 发送期间按路径缓存的文件句柄：省掉每个 512 KiB 分块两次 open/close。
  final Map<String, RandomAccessFile> _fileHandles = {};

  Future<Uint8List> readChunk(TransferItem item, int offset, int length) async {
    if (length <= 0) return Uint8List(0);
    final data = item.data;
    if (data != null) {
      // 文字消息按 UTF-8 字节走同一套分块协议，不设长度上限。
      if (offset >= data.length) return Uint8List(0);
      final end = offset + length > data.length ? data.length : offset + length;
      return Uint8List.sublistView(data, offset, end);
    }
    if (item.uri != null) {
      final bytes = await _channel.invokeMethod<Uint8List>('readChunk', {
        'uri': item.uri,
        'offset': offset,
        'length': length,
      });
      if (bytes == null) throw StateError('无法读取 ${item.name}');
      return bytes;
    }
    final path = item.path;
    if (path == null) throw StateError('文件路径不可用：${item.name}');
    final cached = _fileHandles[path];
    if (cached != null) {
      await cached.setPosition(offset);
      return await cached.read(length);
    }
    final file = await File(path).open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  /// 开始发送一个路径型文件前持有句柄；传输结束由 [releaseItemHandles] 释放。
  Future<void> holdItemHandle(TransferItem item) async {
    final path = item.path;
    if (path == null || _fileHandles.containsKey(path)) return;
    _fileHandles[path] = await File(path).open();
  }

  Future<void> releaseItemHandles(TransferItem item) async {
    final path = item.path;
    if (path == null) return;
    final handle = _fileHandles.remove(path);
    if (handle == null) return;
    try {
      await handle.close();
    } catch (_) {
      // 句柄可能已因文件被删除等原因失效。
    }
  }

  Future<void> closeAllHandles() async {
    final handles = List.of(_fileHandles.values);
    _fileHandles.clear();
    for (final handle in handles) {
      try {
        await handle.close();
      } catch (_) {}
    }
  }

  /// 计算源文件的真实字节数与 SHA-256。
  ///
  /// 关键：不信任外部传入的 [item.size]（file_picker / ContentProvider 对
  /// 部分视频、云文件会报小，导致只发前半段却校验通过 = 文件缩水）。
  /// 这里一直读到 EOF，以实际读到的字节数为准。
  /// 零字节文件合法：读不到任何数据时返回空摘要，允许照常发送。
  Future<({String hash, int size})> hashItem(TransferItem item) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    var total = 0;
    while (true) {
      final chunk = await readChunk(item, total, transferChunkSize);
      if (chunk.isEmpty) break;
      input.add(chunk);
      total += chunk.length;
    }
    input.close();
    final digest = output.events.isEmpty
        ? sha256.convert(const <int>[])
        : output.events.single;
    return (hash: digest.toString(), size: total);
  }

  Future<String> hashFile(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = output.events.isEmpty
        ? sha256.convert(const <int>[])
        : output.events.single;
    return digest.toString();
  }

  Future<Directory> receiveDirectory() async {
    final String root;
    if (isAndroid) {
      root = '/storage/emulated/0/Download/YuanChuan';
    } else {
      final downloads = await getDownloadsDirectory();
      final downloadsRoot = downloads?.path ??
          p.join((await getApplicationDocumentsDirectory()).path, 'Downloads');
      root = p.join(downloadsRoot, 'YuanChuan');
    }
    final directory = Directory(root);
    await directory.create(recursive: true);
    final incoming = Directory(p.join(root, '.incoming'));
    await incoming.create(recursive: true);
    return directory;
  }

  Future<bool> hasStorageAccess() async {
    if (!isAndroid) return true;
    return await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
  }

  Future<bool> requestStorageAccess() async {
    if (!isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestStorageAccess') ?? false;
  }

  Future<void> requestNotificationPermission() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('requestNotificationPermission');
  }

  Future<void> startBackgroundService() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('startBackgroundService');
  }

  Future<void> stopBackgroundService() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('stopBackgroundService');
  }

  Future<bool> hasOverlayPermission() async {
    if (!isAndroid) return false;
    return await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
  }

  Future<void> requestOverlayPermission() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('requestOverlayPermission');
  }

  Future<bool> isFloatingWindowEnabled() async {
    if (!isAndroid) return false;
    return await _channel.invokeMethod<bool>('isFloatingWindowEnabled') ??
        false;
  }

  Future<void> setFloatingWindow(bool enabled) async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('setFloatingWindow', {
      'enabled': enabled,
    });
  }

  Future<bool> isBootAutostartEnabled() async {
    if (!isAndroid) return false;
    return await _channel.invokeMethod<bool>('isBootAutostartEnabled') ?? false;
  }

  Future<void> setBootAutostart(bool enabled) async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('setBootAutostart', {
      'enabled': enabled,
    });
  }

  Future<void> updateBackgroundService(String text) async {
    if (!isAndroid) return;
    await _channel
        .invokeMethod<void>('updateBackgroundService', {'text': text});
  }

  Map<String, dynamic> encodeItems(List<TransferItem> items) =>
      {'items': jsonEncode(items.map((item) => item.toJson()).toList())};

  /// 把拖放进来的本机路径（文件或文件夹）转成待传输条目。
  /// 文件夹保留目录层级；拖入多个文件夹时各自以根目录名作前缀。
  /// 相对路径统一用 `/` 分隔，与传输协议保持一致。
  Future<List<TransferItem>> itemsFromPaths(List<String> paths) async {
    final items = <TransferItem>[];
    for (final raw in paths) {
      final type = FileSystemEntity.typeSync(raw);
      if (type == FileSystemEntityType.directory) {
        final rootName = p.basename(raw);
        final entities = await Directory(raw).list(recursive: true).toList();
        final files = entities.whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in files) {
          final relative =
              p.relative(file.path, from: raw).replaceAll('\\', '/');
          items.add(TransferItem(
            id: randomId(),
            name: p.basename(file.path),
            relativePath: '$rootName/$relative',
            size: await file.length(),
            path: file.path,
          ));
        }
      } else if (type == FileSystemEntityType.file) {
        items.add(TransferItem(
          id: randomId(),
          name: p.basename(raw),
          relativePath: p.basename(raw),
          size: await File(raw).length(),
          path: raw,
        ));
      }
    }
    return items;
  }
}
