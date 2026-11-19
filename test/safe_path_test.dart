import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/platform_gateway.dart';
import 'package:local_file_drop/services/safe_path.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('保留正常中文文件名和目录层级', () {
    expect(safeRelativePath('相册/原图/全家福.jpg'), '相册/原图/全家福.jpg');
    expect(safeRelativePath('folder\\video.mp4'), 'folder/video.mp4');
  });

  test('阻止绝对路径和目录穿越', () {
    expect(() => safeRelativePath('../secret'), throwsFormatException);
    expect(() => safeRelativePath('a/../../secret'), throwsFormatException);
    expect(() => safeRelativePath('/absolute/file'), throwsFormatException);
    expect(() => safeRelativePath('C:/windows/file'), throwsFormatException);
  });

  test('同名文件自动加序号且不覆盖', () async {
    final root =
        await Directory.systemTemp.createTemp('local_file_drop_path_test');
    try {
      final original = File(p.join(root.path, '照片.jpg'));
      await original.writeAsString('original');
      final first = await uniqueDestination(root, '照片.jpg');
      expect(p.basename(first.path), '照片 (1).jpg');
      await first.writeAsString('first');
      final second = await uniqueDestination(root, '照片.jpg');
      expect(p.basename(second.path), '照片 (2).jpg');
      expect(await original.readAsString(), 'original');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('拖入的文件和文件夹转成传输条目并保留层级', () async {
    final gateway = PlatformGateway();
    final root =
        await Directory.systemTemp.createTemp('local_file_drop_drop_test');
    try {
      final folder = Directory(p.join(root.path, '资料夹'));
      final nested = Directory(p.join(folder.path, '子目录'));
      await nested.create(recursive: true);
      final inside = File(p.join(nested.path, '图.png'));
      await inside.writeAsBytes([1, 2, 3]);
      final loose = File(p.join(root.path, '说明.txt'));
      await loose.writeAsString('hello');
      final items = await gateway.itemsFromPaths([folder.path, loose.path]);
      final relativePaths = items.map((item) => item.relativePath).toList();
      expect(
          relativePaths,
          containsAll([
            '资料夹/子目录/图.png',
            '说明.txt',
          ]));
      final imageItem = items.singleWhere((item) => item.name == '图.png');
      expect(imageItem.size, 3);
      expect(imageItem.path, inside.path);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
