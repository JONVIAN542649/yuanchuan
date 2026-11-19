/// 单条传输的瞬时速率采样。
///
/// 喂入“累计字节数 + 时间戳”样本，按滚动窗口首尾差计算每秒速率；
/// 字节数回退（断点重开、校验失败归零）时自动作废旧样本。
class TransferThroughput {
  TransferThroughput({this.window = const Duration(seconds: 3)});

  final Duration window;
  final List<(DateTime, int)> _samples = [];

  void add(int totalBytes, DateTime at) {
    if (_samples.isNotEmpty && totalBytes < _samples.last.$2) {
      _samples.clear();
    }
    if (_samples.isNotEmpty && !at.isAfter(_samples.last.$1)) {
      // 时间倒流（同一毫秒内的多次更新）只刷新字节计数。
      _samples[_samples.length - 1] = (_samples.last.$1, totalBytes);
      return;
    }
    _samples.add((at, totalBytes));
    final earliest = at.subtract(window);
    while (_samples.length > 2 && _samples.first.$1.isBefore(earliest)) {
      _samples.removeAt(0);
    }
  }

  /// 每秒字节数。样本间隔不足 300ms 或窗口内无增长时返回 null，
  /// UI 据此显示“测速中”而不是误导性的 0。
  int? bytesPerSecond() {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = last.$1.difference(first.$1).inMilliseconds;
    if (elapsed < 300) return null;
    final delta = last.$2 - first.$2;
    if (delta <= 0) return null;
    return (delta * 1000 / elapsed).round();
  }

  void reset() => _samples.clear();
}

/// 把剩余字节与速率换算成“3分20秒”这类人话；无法估算时返回 null。
String? formatEta(int? bytesPerSecond, int remainingBytes) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return null;
  if (remainingBytes <= 0) return null;
  final seconds = (remainingBytes / bytesPerSecond).ceil();
  if (seconds >= 3600) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return minutes > 0 ? '$hours小时$minutes分' : '$hours小时';
  }
  if (seconds >= 60) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest > 0 ? '$minutes分$rest秒' : '$minutes分';
  }
  return '$seconds秒';
}
