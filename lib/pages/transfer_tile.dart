// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';
import '../services/speed_monitor.dart';

/// 单条传输记录卡片：悬浮小窗与“传输”页共用。
class TransferTile extends StatelessWidget {
  const TransferTile({required this.record, required this.appState, super.key});

  final TransferRecord record;
  final AppState appState;

  Future<void> _confirmReceived(BuildContext context) async {
    try {
      await appState.confirmReceived(record);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(record.isTextRecord ? '文字已复制，直接粘贴即可' : '文件已复制，可直接粘贴到文件夹'),
        ));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消这次传输？'),
        content: Text(record.direction == TransferDirection.receiving
            ? '已接收的未完成部分会被删除，不会留下残缺文件。'
            : '发送会立即停止，对端的未完成部分也会被清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续传输'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('取消并清理'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await appState.transferManager.cancel(record.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sending = record.direction == TransferDirection.sending;
    final active = record.active;
    final pending = appState.isPendingReceived(record);
    final canConfirm = pending &&
        (record.isTextRecord
            ? record.textContent != null
            : appState.isDesktop && record.savePath != null);
    final speed = record.status == TransferStatus.transferring
        ? appState.transferManager.speedOf(record.id)
        : null;
    final eta = speed == null
        ? null
        : formatEta(speed, record.size - record.bytesTransferred);
    final color = switch (record.status) {
      TransferStatus.completed => Colors.green,
      TransferStatus.failed => Colors.red,
      TransferStatus.cancelled => Colors.grey,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  record.isTextRecord
                      ? Icons.text_snippet_outlined
                      : (sending ? Icons.north_east : Icons.south_west),
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                Text(
                  transferStatusText(record.status),
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (active || record.status == TransferStatus.paused) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: record.progress.clamp(0, 1),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 4),
              Text(
                '${formatBytes(record.bytesTransferred)} / ${formatBytes(record.size)}'
                ' · ${(record.progress * 100).toStringAsFixed(1)}%'
                '${speed == null ? '' : ' · ${formatBytes(speed)}/s'}'
                '${eta == null ? '' : ' · 剩余 $eta'}',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
            if (record.error != null) ...[
              const SizedBox(height: 6),
              Text(
                record.error!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (record.isTextRecord &&
                record.textContent != null &&
                record.status == TransferStatus.completed) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F5F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  record.textContent!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF37474F), height: 1.45),
                ),
              ),
            ],
            if (record.savePath != null &&
                record.status == TransferStatus.completed) ...[
              const SizedBox(height: 6),
              Text(
                '保存位置：${record.savePath}',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (canConfirm) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFF087F8C),
                  ),
                  onPressed: () => _confirmReceived(context),
                  icon: const Icon(Icons.content_paste_go, size: 16),
                  label: const Text('确认接收并复制', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
            if ((active &&
                    record.status != TransferStatus.verifying &&
                    record.status != TransferStatus.hashing) ||
                record.status == TransferStatus.paused ||
                (sending &&
                    (record.status == TransferStatus.failed ||
                        record.status == TransferStatus.cancelled))) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (active)
                    TextButton.icon(
                      onPressed: () =>
                          appState.transferManager.pause(record.id),
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('暂停', style: TextStyle(fontSize: 12)),
                    )
                  else if (sending)
                    TextButton.icon(
                      onPressed: () =>
                          appState.transferManager.resume(record.id),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('继续', style: TextStyle(fontSize: 12)),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('在发送端点“继续”即可续传',
                          style: TextStyle(color: Colors.grey, fontSize: 11)),
                    ),
                  if (active || record.status == TransferStatus.paused)
                    TextButton.icon(
                      onPressed: () => _confirmCancel(context),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('取消', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
