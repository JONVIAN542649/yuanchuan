import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/connection_path.dart';

void main() {
  test('直连先成功则选用直连并记住', () async {
    final memory = ConnectionPathMemory();
    final losers = <String>[];
    final result = await memory.race<String>(
      direct: () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'direct';
      },
      relay: () async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return 'relay';
      },
      onLose: losers.add,
      overallTimeout: const Duration(seconds: 2),
    );
    expect(result?.kind, TransferPathKind.direct);
    expect(result?.value, 'direct');
    expect(memory.lastSuccess, TransferPathKind.direct);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(losers, ['relay']);
  });

  test('直连失败时中继仍可胜出（不因 null 提前结束）', () async {
    final memory = ConnectionPathMemory();
    final result = await memory.race<String>(
      direct: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return null;
      },
      relay: () async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return 'relay';
      },
      onLose: (_) {},
      overallTimeout: const Duration(seconds: 2),
    );
    expect(result?.kind, TransferPathKind.relay);
    expect(result?.value, 'relay');
    expect(memory.lastSuccess, TransferPathKind.relay);
  });

  test('偏好路径抢先窗口：上次直连成功则优先等直连', () async {
    final memory = ConnectionPathMemory()..remember(TransferPathKind.direct);
    final result = await memory.race<String>(
      direct: () async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 'direct';
      },
      relay: () async {
        // 中继更快，但偏好窗口内直连仍应胜出。
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'relay';
      },
      onLose: (_) {},
      overallTimeout: const Duration(seconds: 2),
    );
    expect(result?.kind, TransferPathKind.direct);
  });
}
