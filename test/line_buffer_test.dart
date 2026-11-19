import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/line_buffer.dart';

void main() {
  test('TCP 粘包：一次读出多行', () {
    final buffer = LineBuffer();
    final lines = buffer.add(utf8.encode('INCOMING D:abc\nPONG\n'));
    expect(lines, ['INCOMING D:abc', 'PONG']);
    expect(buffer.pendingBytes, 0);
  });

  test('TCP 拆包：跨多次读拼成一行', () {
    final buffer = LineBuffer();
    expect(buffer.add(utf8.encode('INCOM')), isEmpty);
    expect(buffer.add(utf8.encode('ING D:xy')), isEmpty);
    expect(buffer.add(utf8.encode('z\n')), ['INCOMING D:xyz']);
  });

  test('忽略孤立的回车并保留不完整尾部', () {
    final buffer = LineBuffer();
    final lines = buffer.add(utf8.encode('A\r\nB'));
    expect(lines, ['A']);
    expect(buffer.pendingBytes, 1);
    expect(buffer.add(utf8.encode('\n')), ['B']);
  });
}
