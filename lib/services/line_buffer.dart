import 'dart:convert';
import 'dart:typed_data';

/// TCP 按行缓冲：把可能被合并/拆分的 socket 字节流拼成完整行（以 `\n` 结尾）。
///
/// 中继协议的控制面是 ASCII 行协议；绝不能把一次 `Socket` 读事件当成一行，
/// 否则 `INCOMING ...` 可能被截断或与后续桥接字节粘连。
class LineBuffer {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// 追加一段原始字节，返回本批可完整解析出的行（不含末尾 `\n`）。
  List<String> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    _pending.add(chunk);
    final data = _pending.takeBytes();
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0x0A) continue; // '\n'
      var end = i;
      if (end > start && data[end - 1] == 0x0D) end--; // 去掉可选 `\r`
      lines.add(utf8.decode(data.sublist(start, end)));
      start = i + 1;
    }
    if (start < data.length) {
      _pending.add(Uint8List.sublistView(data, start));
    }
    return lines;
  }

  /// 当前尚未凑成完整行的字节数（测试/诊断用）。
  int get pendingBytes => _pending.length;

  void clear() => _pending.clear();
}
