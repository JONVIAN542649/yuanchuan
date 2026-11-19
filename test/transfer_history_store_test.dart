import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/models/transfer_models.dart';
import 'package:local_file_drop/services/transfer_history_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('yc_history');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('防抖写入独立文件并可重新加载', () async {
    final store = TransferHistoryStore(
      overrideDirectory: temp,
      debounce: const Duration(milliseconds: 50),
    );
    final now = DateTime.now();
    store.scheduleSave([
      TransferRecord(
        id: 'a1',
        deviceId: 'd1',
        deviceName: '电脑',
        name: 'a.bin',
        relativePath: 'a.bin',
        size: 10,
        direction: TransferDirection.sending,
        status: TransferStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await store.flush();
    expect(File(p.join(temp.path, 'transfer_history.json')).existsSync(), isTrue);

    final reloaded = TransferHistoryStore(
      overrideDirectory: temp,
      debounce: const Duration(milliseconds: 50),
    );
    final records = await reloaded.load();
    expect(records, hasLength(1));
    expect(records.first.name, 'a.bin');
  });
}
