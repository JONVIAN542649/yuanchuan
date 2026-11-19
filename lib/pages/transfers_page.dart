import 'dart:async';
import 'dart:io';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';
import '../services/speed_monitor.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState.transferManager,
      builder: (context, _) {
        final records = appState.transferManager.records.reversed.toList();
        final manager = appState.transferManager;
        final totalSpeed = manager.totalSpeed;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                if (records.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        // SHAREit/Feem 式的总速率：一眼看到“现在跑多快”。
                        if (manager.activeTransferring > 0)
                          Text(
                            '${manager.activeTransferring} 个任务 · 总速率 ${formatBytes(totalSpeed)}/s',
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF087F8C)),
                          ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: manager.clearFinishedHistory,
                          icon: const Icon(Icons.cleaning_services_outlined,
                              size: 18),
                          label: const Text('清理已结束记录',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: records.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.swap_vert,
                                  size: 54, color: Color(0xFF9AA7AB)),
                              SizedBox(height: 14),
                              Text('还没有传输记录',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF37474F))),
                              SizedBox(height: 6),
                              Text('在“设备”页选择信任设备即可发送原文件',
                                  style: TextStyle(
                                      fontSize: 13, color: Color(0xFF5A6A70))),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                          itemCount: records.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) => _RecordCard(
                              record: records[index], appState: appState),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.appState});

  final TransferRecord record;
  final AppState appState;

  /// 本设备上的目标文件：接收→保存路径；发送→源文件路径。
  String? get _localPath => record.direction == TransferDirection.receiving
      ? record.savePath
      : record.item?.path;

  Future<void> _openLocation(BuildContext context) async {
    final path = _localPath;
    if (path == null || path.isEmpty) {
      _toast(context, '这条记录没有可打开的本地文件');
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      if (context.mounted) _toast(context, '文件已不存在或已移动');
      return;
    }
    if (Platform.isWindows) {
      // explorer /select 会打开资源管理器并高亮选中该文件。
      await Process.run('explorer.exe', ['/select,$path']);
      return;
    }
    try {
      await const MethodChannel('local_file_drop/system')
          .invokeMethod<bool>('openPath', path);
    } on PlatformException {
      if (context.mounted) _toast(context, '无法打开该文件');
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final receiving = record.direction == TransferDirection.receiving;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消这次传输？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          receiving
              ? '取消后将删除已接收的不完整文件，不会在保存位置留下残缺文件。'
              : '取消后本次发送立即停止，对方的接收进度也会一并取消。',
          style: const TextStyle(fontSize: 13.5, color: Color(0xFF5A6A70)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续传输'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消传输'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      unawaited(appState.transferManager.cancel(record.id));
    }
  }

  Future<void> _confirmReceivedCopy(BuildContext context) async {
    try {
      await appState.confirmReceived(record);
      if (context.mounted) {
        _toast(
          context,
          record.isTextRecord ? '文字已复制，直接粘贴即可' : '文件已复制，可直接粘贴到文件夹',
        );
      }
    } catch (error) {
      if (context.mounted) _toast(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sending = record.direction == TransferDirection.sending;
    final active = record.active;
    final color = switch (record.status) {
      TransferStatus.completed => Colors.green,
      TransferStatus.failed => Colors.red,
      TransferStatus.cancelled => Colors.grey,
      _ => Theme.of(context).colorScheme.primary,
    };
    final canOpen = _localPath != null && _localPath!.isNotEmpty;
    final speed = record.status == TransferStatus.transferring
        ? appState.transferManager.speedOf(record.id)
        : null;
    final eta = speed == null
        ? null
        : formatEta(speed, record.size - record.bytesTransferred);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canOpen
            ? () {
                unawaited(_openLocation(context));
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: color.withValues(alpha: .12),
                    foregroundColor: color,
                    child: Icon(sending ? Icons.north_east : Icons.south_west,
                        size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(record.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF212B2E))),
                        const SizedBox(height: 3),
                        Text(
                            '${sending ? '发送给' : '来自'} ${record.deviceName} · ${formatBytes(record.size)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF5A6A70))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(transferStatusText(record.status),
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              if (active || record.status == TransferStatus.paused) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                    value: record.progress.clamp(0, 1),
                    minHeight: 7,
                    borderRadius: BorderRadius.circular(8)),
                const SizedBox(height: 6),
                Text(
                    '${formatBytes(record.bytesTransferred)} / ${formatBytes(record.size)}'
                    ' · ${(record.progress * 100).toStringAsFixed(1)}%'
                    '${speed == null ? '' : ' · ${formatBytes(speed)}/s'}'
                    '${eta == null ? '' : ' · 剩余 $eta'}',
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF5A6A70))),
              ],
              if (record.error != null) ...[
                const SizedBox(height: 10),
                Text(record.error!,
                    style:
                        TextStyle(color: Colors.red.shade700, fontSize: 12.5)),
              ],
              if (record.isTextRecord &&
                  record.textContent != null &&
                  record.status == TransferStatus.completed) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F5F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    record.textContent!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF37474F), height: 1.45),
                  ),
                ),
              ],
              if (record.savePath != null &&
                  record.status == TransferStatus.completed) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.folder_open_outlined,
                        size: 14, color: Color(0xFF5A6A70)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        canOpen
                            ? '保存位置（点击打开）：${record.savePath}'
                            : '保存位置：${record.savePath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xFF5A6A70), fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ],
              if (appState.isPendingReceived(record) &&
                  (record.isTextRecord ||
                      (appState.isDesktop && record.savePath != null))) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF087F8C),
                    ),
                    onPressed: () => _confirmReceivedCopy(context),
                    icon: const Icon(Icons.content_paste_go, size: 17),
                    label:
                        const Text('确认接收并复制', style: TextStyle(fontSize: 13)),
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
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (active)
                      TextButton.icon(
                          onPressed: () =>
                              appState.transferManager.pause(record.id),
                          icon: const Icon(Icons.pause, size: 18),
                          label:
                              const Text('暂停', style: TextStyle(fontSize: 13)))
                    else if (sending)
                      TextButton.icon(
                          onPressed: () =>
                              appState.transferManager.resume(record.id),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label:
                              const Text('继续', style: TextStyle(fontSize: 13)))
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('在发送端点“继续”即可续传',
                            style: TextStyle(
                                color: Color(0xFF5A6A70), fontSize: 12.5)),
                      ),
                    if (active || record.status == TransferStatus.paused)
                      TextButton.icon(
                          onPressed: () => _confirmCancel(context),
                          icon: const Icon(Icons.close,
                              size: 18, color: Color(0xFFE53935)),
                          label: const Text('取消',
                              style: TextStyle(
                                  fontSize: 13, color: Color(0xFFE53935)))),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
