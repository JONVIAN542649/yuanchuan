import 'package:desktop_drop/desktop_drop.dart';
// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';
import '../services/window_presenter.dart';
import 'device_chooser.dart';
import 'text_compose_dialog.dart';
import 'transfer_tile.dart';
import 'window_mode_menu.dart';

/// 夸克式小窗：点悬浮条展开。顶部发送目标与操作，下方传输记录。
/// 整个面板都是拖放目标：把文件拖进来即发送。
class QuickPanel extends StatefulWidget {
  const QuickPanel({required this.appState, super.key});

  final AppState appState;

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel> {
  bool _dragHover = false;
  DiscoveredDevice? _target;

  Future<void> _handleDrop(List<String> paths) async {
    var device = _target;
    if (device == null) {
      device = await chooseOnlineDevice(context, widget.appState);
      if (device == null) return;
      _target = device;
    }
    await widget.appState.sendDroppedPaths(device, paths);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已发送到 ${device.device.name}'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    return AnimatedBuilder(
      animation: Listenable.merge([appState, appState.transferManager]),
      builder: (context, _) {
        final online = appState.onlineDevices;
        if (_target != null &&
            !online.any((item) => item.device.id == _target!.device.id)) {
          _target = null;
        }
        final pending = appState.pendingReceivedRecords;
        return DropTarget(
          onDragEntered: (_) => setState(() => _dragHover = true),
          onDragExited: (_) => setState(() => _dragHover = false),
          onDragDone: (details) {
            setState(() => _dragHover = false);
            _handleDrop([for (final file in details.files) file.path]);
          },
          child: Container(
            color:
                _dragHover ? const Color(0xFFE0F2F1) : const Color(0xFFF5F7F8),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PanelHeader(appState: appState),
                  if (pending.isNotEmpty)
                    _PendingStrip(appState: appState, records: pending),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: _TargetRow(
                      appState: appState,
                      online: online,
                      target: _target,
                      onTargetChanged: (device) =>
                          setState(() => _target = device),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '拖动顶部可移动窗口，拖动边缘可缩放；把文件拖进本窗口即可发送。',
                      style: TextStyle(color: Color(0xFF5A6A70), fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _RecordList(appState: appState),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => WindowPresenter.startDragging(),
      onSecondaryTapDown: (details) =>
          showWindowMenuAt(context, appState, details.globalPosition),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE5E9EB))),
        ),
        child: Row(
          children: [
            const Icon(Icons.all_inclusive, color: Color(0xFF087F8C), size: 21),
            const SizedBox(width: 8),
            const Text(
              '原传',
              style: TextStyle(
                color: Color(0xFF1F2A2D),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '收起为悬浮条',
              visualDensity: VisualDensity.compact,
              onPressed: () => appState.setDisplayMode(DisplayMode.bar),
              icon: const Icon(Icons.horizontal_rule,
                  color: Color(0xFF54666B), size: 20),
            ),
            IconButton(
              tooltip: '打开完整窗口',
              visualDensity: VisualDensity.compact,
              onPressed: () => appState.setDisplayMode(DisplayMode.full),
              icon: const Icon(Icons.open_in_full,
                  color: Color(0xFF54666B), size: 18),
            ),
            WindowModeButton(appState: appState),
          ],
        ),
      ),
    );
  }
}

class _PendingStrip extends StatelessWidget {
  const _PendingStrip({required this.appState, required this.records});

  final AppState appState;
  final List<TransferRecord> records;

  @override
  Widget build(BuildContext context) {
    final shown = records.take(3).toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD8A8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_active,
                  color: Color(0xFFE65100), size: 18),
              const SizedBox(width: 6),
              Text(
                '收到 ${records.length} 项，确认后自动复制',
                style: const TextStyle(
                  color: Color(0xFF8A3B00),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final record in shown)
            Row(
              children: [
                Icon(
                  record.isTextRecord
                      ? Icons.text_snippet_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 16,
                  color: const Color(0xFF8A3B00),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    record.isTextRecord ? '文字消息' : record.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFF087F8C),
                  ),
                  onPressed: () async {
                    try {
                      await appState.confirmReceived(record);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(record.isTextRecord
                              ? '文字已复制，直接粘贴即可'
                              : '文件已复制，可直接粘贴到文件夹'),
                        ));
                      }
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$error')));
                      }
                    }
                  },
                  child: const Text('接收并复制'),
                ),
              ],
            ),
          if (records.length > shown.length)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '其余可在下方传输记录中逐条确认',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF8A5A2B)),
              ),
            ),
        ],
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.appState,
    required this.online,
    required this.target,
    required this.onTargetChanged,
  });

  final AppState appState;
  final List<DiscoveredDevice> online;
  final DiscoveredDevice? target;
  final void Function(DiscoveredDevice?) onTargetChanged;

  @override
  Widget build(BuildContext context) {
    final effective = target ?? (online.length == 1 ? online.single : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButton<DiscoveredDevice>(
          isExpanded: true,
          value: effective,
          hint: Text(online.isEmpty ? '没有在线设备' : '选择发送目标'),
          items: [
            for (final device in online)
              DropdownMenuItem(
                value: device,
                child: Text(
                  '${device.device.name}（在线）',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (device) => onTargetChanged(device),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: effective == null
                    ? null
                    : () => composeAndSendText(context, appState, effective),
                icon: const Icon(Icons.text_fields, size: 17),
                label: const Text('传文字', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: effective == null
                    ? null
                    : () => appState.sendFiles(effective),
                icon: const Icon(Icons.insert_drive_file_outlined, size: 17),
                label: const Text('传文件', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: effective == null
                    ? null
                    : () => appState.sendFolder(effective),
                icon: const Icon(Icons.folder_outlined, size: 17),
                label: const Text('传文件夹', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecordList extends StatelessWidget {
  const _RecordList({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final records = appState.transferManager.records.reversed.toList();
    if (records.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 40, color: Color(0xFF9AA7AB)),
            SizedBox(height: 8),
            Text('还没有传输记录',
                style: TextStyle(fontSize: 13, color: Color(0xFF5A6A70))),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: records.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          TransferTile(record: records[index], appState: appState),
    );
  }
}
