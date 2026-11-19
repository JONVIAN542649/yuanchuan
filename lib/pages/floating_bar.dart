import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/window_presenter.dart';
import 'device_chooser.dart';
import 'window_mode_menu.dart';

/// 夸克网盘式悬浮条：默认贴近系统搜索栏大小，可拖动、可拉伸。
///
/// 点击：展开小窗（有新接收内容时红点提示，在小窗里确认并自动复制）；
/// 拖文件到条上：立即发送；右键：快速切换主窗/小窗/悬浮条/托盘。
class FloatingBar extends StatefulWidget {
  const FloatingBar({required this.appState, super.key});

  final AppState appState;

  @override
  State<FloatingBar> createState() => _FloatingBarState();
}

class _FloatingBarState extends State<FloatingBar> {
  bool _dragHover = false;
  String? _flash;
  Timer? _flashTimer;

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  void _showFlash(String text) {
    _flashTimer?.cancel();
    setState(() => _flash = text);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  Future<void> _onTap() async {
    await widget.appState.setDisplayMode(DisplayMode.panel);
  }

  Future<void> _handleDrop(List<String> paths) async {
    final device = await chooseOnlineDevice(context, widget.appState);
    if (device == null) return;
    await widget.appState.sendDroppedPaths(device, paths);
    _showFlash('已发送到 ${device.device.name}');
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    return AnimatedBuilder(
      animation: Listenable.merge([appState, appState.transferManager]),
      builder: (context, _) {
        final pending = appState.pendingReceivedRecords.length;
        final activeRecords = [
          for (final record in appState.transferManager.records)
            if (record.active) record,
        ];
        final busy = activeRecords.isNotEmpty;
        final progress = busy
            ? activeRecords
                    .map((record) => record.progress.clamp(0.0, 1.0))
                    .reduce((a, b) => a + b) /
                activeRecords.length
            : null;
        return DropTarget(
          onDragEntered: (_) => setState(() => _dragHover = true),
          onDragExited: (_) => setState(() => _dragHover = false),
          onDragDone: (details) {
            setState(() => _dragHover = false);
            _handleDrop([for (final file in details.files) file.path]);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              onPanStart: (_) => WindowPresenter.startDragging(),
              onSecondaryTapDown: (details) =>
                  showWindowMenuAt(context, appState, details.globalPosition),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _dragHover
                      ? const Color(0xFF0A97A6)
                      : const Color(0xF0087F8C),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x44000000),
                      blurRadius: 14,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_flash != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _flash!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      Row(
                        children: [
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (busy)
                                  SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      value: progress,
                                      valueColor: const AlwaysStoppedAnimation(
                                          Colors.white),
                                      backgroundColor: Colors.white24,
                                    ),
                                  ),
                                const Icon(Icons.all_inclusive,
                                    color: Colors.white, size: 19),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                busy
                                    ? '传输中 ${(progress! * 100).round()}%'
                                    : '原传',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          if (pending > 0)
                            Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 5),
                              constraints: const BoxConstraints(minWidth: 16),
                              height: 16,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE53935),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: const Color(0xF0087F8C), width: 1),
                              ),
                              child: Text(
                                pending > 9 ? '9+' : '$pending',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
