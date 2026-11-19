import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/content_hash.dart';

void main() {
  test('内容哈希稳定且与 String.hashCode 无关', () {
    const text = '原传剪贴板内容';
    final a = contentHash(text);
    final b = contentHash(text);
    expect(a, b);
    expect(a.length, 64);
    expect(clipboardDedupKey(text), 't:$a');
    // 不同内容必须不同（抗碰撞的基本要求）。
    expect(contentHash('原传剪贴板内容!'), isNot(a));
  });
}
