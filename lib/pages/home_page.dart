// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../services/app_state.dart';
import 'devices_page.dart';
import 'settings_page.dart';
import 'chat_page.dart';
import 'update_page.dart';
import 'window_mode_menu.dart';

class HomePage extends StatefulWidget {
  const HomePage({required this.appState, super.key});

  final AppState appState;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _index = 0;
  bool _updateShown = false;

  @override
  void initState() {
    super.initState();
    widget.appState.onUpdateAvailable = (release) {
      if (_updateShown || !mounted) return;
      _updateShown = true;
      showDialog<void>(
        context: context,
        builder: (_) => UpdateDialog(release: release),
      );
    };
  }

  @override
  void dispose() {
    widget.appState.onUpdateAvailable = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DevicesPage(appState: widget.appState),
      ChatPage(appState: widget.appState),
      SettingsPage(appState: widget.appState),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.all_inclusive, size: 24, color: Color(0xFF087F8C)),
            SizedBox(width: 10),
            Text('原传',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2A2D))),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        actions: widget.appState.isDesktop
            ? [
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    foregroundColor: widget.appState.desktopPinned
                        ? const Color(0xFF087F8C)
                        : const Color(0xFF54666B),
                  ),
                  onPressed: () => widget.appState.toggleDesktopPinned(),
                  child: Text(
                    widget.appState.desktopPinned ? '已置顶' : '置顶',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                WindowModeButton(
                  appState: widget.appState,
                  color: const Color(0xFF54666B),
                ),
                const SizedBox(width: 2),
              ]
            : null,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: ColoredBox(color: Color(0xFFE5E9EB)),
        ),
      ),
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.devices_outlined),
              selectedIcon: Icon(Icons.devices),
              label: '设备'),
          NavigationDestination(
              icon: Icon(Icons.swap_vert_outlined),
              selectedIcon: Icon(Icons.swap_vert),
              label: '传输'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}
