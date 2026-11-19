import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/stable_file.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('yc_stable_file');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('文件大小稳定后返回最终长度', () async {
    final file = File(p.join(temp.path, 'growing.bin'));
    await file.writeAsBytes(List.filled(100, 1));
    final pending = waitUntilFileStable(
      file,
      pollInterval: const Duration(milliseconds: 40),
      stableChecks: 3,
      timeout: const Duration(seconds: 5),
    );
    // 在判定稳定前继续写入，最终应得到 500。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await file.writeAsBytes(List.filled(500, 2));
    final size = await pending;
    expect(size, 500);
  });
}
