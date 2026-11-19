import 'dart:io';

import 'package:path/path.dart' as p;

String safeRelativePath(String raw) {
  final normalized = raw.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains(':')) {
    throw const FormatException('文件相对路径无效');
  }
  final output = <String>[];
  for (final original in normalized.split('/')) {
    if (original.isEmpty || original == '.' || original == '..') {
      throw const FormatException('文件相对路径包含非法目录');
    }
    var segment = original.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    segment = segment.replaceAll(RegExp(r'[. ]+$'), '');
    if (segment.isEmpty) segment = '_';
    final base = segment.split('.').first.toUpperCase();
    const reserved = {
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    if (reserved.contains(base)) segment = '${segment}_';
    output.add(segment);
  }
  return output.join('/');
}

Future<File> uniqueDestination(Directory root, String relativePath) async {
  final safe = safeRelativePath(relativePath);
  final parts = safe.split('/');
  final rootPath = p.normalize(root.absolute.path);
  var candidate = p.normalize(p.joinAll([rootPath, ...parts]));
  if (!p.isWithin(rootPath, candidate)) {
    throw const FormatException('保存路径越出接收目录');
  }
  final directory = Directory(p.dirname(candidate));
  await directory.create(recursive: true);
  if (!await File(candidate).exists()) return File(candidate);

  final extension = p.extension(candidate);
  final withoutExtension = extension.isEmpty
      ? candidate
      : candidate.substring(0, candidate.length - extension.length);
  for (var index = 1; index < 100000; index++) {
    candidate = '$withoutExtension ($index)$extension';
    if (!await File(candidate).exists()) return File(candidate);
  }
  throw StateError('同名文件过多，无法生成新文件名');
}
