import 'dart:async';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../services/app_state.dart';

/// 三种窗口形态的快捷入口：主窗、小窗、悬浮条，以及隐藏到托盘。
enum WindowMenuAction { full, panel, bar, hide }

List<PopupMenuEntry<WindowMenuAction>> windowModeMenuItems() => const [
      PopupMenuItem(
        value: WindowMenuAction.full,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.open_in_full, size: 20),
          title: Text('主窗口'),
        ),
      ),
      PopupMenuItem(
        value: WindowMenuAction.panel,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.picture_in_picture_alt_outlined, size: 20),
          title: Text('悬浮小窗'),
        ),
      ),
      PopupMenuItem(
        value: WindowMenuAction.bar,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.horizontal_rule, size: 20),
          title: Text('悬浮条'),
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        value: WindowMenuAction.hide,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.visibility_off_outlined, size: 20),
          title: Text('隐藏到托盘'),
        ),
      ),
    ];

Future<void> _runWindowAction(
    AppState appState, WindowMenuAction action) async {
  switch (action) {
    case WindowMenuAction.full:
      await appState.setDisplayMode(DisplayMode.full, restorePosition: true);
      break;
    case WindowMenuAction.panel:
      await appState.setDisplayMode(DisplayMode.panel);
      break;
    case WindowMenuAction.bar:
      await appState.setDisplayMode(DisplayMode.bar);
      break;
    case WindowMenuAction.hide:
      unawaited(appState.hideToTray());
      break;
  }
}

/// 在鼠标右键位置弹出形态菜单。
Future<void> showWindowMenuAt(
  BuildContext context,
  AppState appState,
  Offset globalPosition,
) async {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return;
  final action = await showMenu<WindowMenuAction>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: windowModeMenuItems(),
  );
  if (action != null) await _runWindowAction(appState, action);
}

/// AppBar / 小窗标题栏共用的形态切换按钮。
class WindowModeButton extends StatelessWidget {
  const WindowModeButton({
    required this.appState,
    this.color = const Color(0xFF54666B),
    super.key,
  });

  final AppState appState;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 36,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: color,
        ),
        onPressed: () {
          final box = context.findRenderObject();
          if (box is! RenderBox) return;
          showWindowMenuAt(
            context,
            appState,
            box.localToGlobal(Offset(box.size.width, box.size.height)),
          );
        },
        child: const Text(
          '切换',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
