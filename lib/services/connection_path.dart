import 'dart:async';

/// 直连 / 中继路径竞速结果。
enum TransferPathKind { direct, relay }

class PathConnectResult<T> {
  const PathConnectResult(this.kind, this.value);

  final TransferPathKind kind;
  final T value;
}

/// 记忆最近一次成功路径；直连与中继并行竞速，谁先成功用谁。
///
/// 旧逻辑：直连超时 10 秒，连续失败 2 次才改走中继，过期局域网地址会卡住用户。
class ConnectionPathMemory {
  TransferPathKind? lastSuccess;

  void remember(TransferPathKind kind) => lastSuccess = kind;

  /// 并行竞速：谁先返回非 null 谁赢；落败/迟到方交给 [onLose] 清理。
  ///
  /// 若 [lastSuccess] 有值，会给该路径约 500ms 抢先窗口，减少无谓双开。
  Future<PathConnectResult<T>?> race<T>({
    required Future<T?> Function() direct,
    required Future<T?> Function() relay,
    required void Function(T loser) onLose,
    Duration overallTimeout = const Duration(seconds: 4),
  }) async {
    final preferred = lastSuccess;
    final directFuture = _guard(TransferPathKind.direct, direct);
    final relayFuture = _guard(TransferPathKind.relay, relay);

    if (preferred != null) {
      final preferredFuture =
          preferred == TransferPathKind.direct ? directFuture : relayFuture;
      final otherFuture =
          preferred == TransferPathKind.direct ? relayFuture : directFuture;
      final early = await Future.any<PathConnectResult<T>?>([
        preferredFuture,
        Future<PathConnectResult<T>?>.delayed(
          const Duration(milliseconds: 500),
          () => null,
        ),
      ]);
      // 仅当偏好路径真正成功时才短路；失败(null)必须继续等另一路径。
      if (early != null) {
        unawaited(otherFuture.then((lost) {
          if (lost != null) onLose(lost.value);
        }));
        remember(early.kind);
        return early;
      }
    }

    final completer = Completer<PathConnectResult<T>?>();
    var remaining = 2;
    PathConnectResult<T>? winner;

    void consider(PathConnectResult<T>? result) {
      if (completer.isCompleted) {
        if (result != null) onLose(result.value);
        return;
      }
      if (result != null) {
        winner = result;
        completer.complete(result);
        return;
      }
      remaining--;
      if (remaining <= 0) completer.complete(null);
    }

    unawaited(directFuture.then(consider));
    unawaited(relayFuture.then(consider));

    try {
      final result = await completer.future.timeout(overallTimeout);
      if (result != null) remember(result.kind);
      return result;
    } on TimeoutException {
      // 总超时后仍可能有迟到的成功，统一回收，避免泄漏 socket/通道。
      unawaited(directFuture.then((late) {
        if (late != null) onLose(late.value);
      }));
      unawaited(relayFuture.then((late) {
        if (late != null) onLose(late.value);
      }));
      if (winner != null) remember(winner!.kind);
      return winner;
    }
  }

  Future<PathConnectResult<T>?> _guard<T>(
    TransferPathKind kind,
    Future<T?> Function() factory,
  ) async {
    try {
      final value = await factory();
      if (value == null) return null;
      return PathConnectResult(kind, value);
    } catch (_) {
      return null;
    }
  }
}

/// 直连短超时（与中继并行时使用）。
const directRaceTimeout = Duration(seconds: 2);
