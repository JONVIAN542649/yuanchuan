// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'dart:io';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
// 桌面端给无边框的悬浮条/小窗补上 8px 透明缩放手柄。
// ignore: deprecated_member_use
import 'package:window_manager/legacy.dart' show DragToResizeArea;

import 'pages/floating_bar.dart';
import 'pages/home_page.dart';
import 'pages/quick_panel.dart';
import 'services/app_state.dart';
import 'services/single_instance.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (!SingleInstance.acquire()) {
    // 已有一个原传在运行：直接退出，避免端口冲突与双悬浮条。
    exit(0);
  }
  final startInFloatingBar = args
      .any((argument) => argument == '--floating' || argument == '/floating');
  final startSilent =
      args.any((argument) => argument == '--silent' || argument == '/silent');
  runApp(YuanChuanApp(
    startInFloatingBar: startInFloatingBar,
    startSilent: startSilent,
  ));
}

class YuanChuanApp extends StatefulWidget {
  const YuanChuanApp({
    required this.startInFloatingBar,
    this.startSilent = false,
    super.key,
  });

  final bool startInFloatingBar;
  final bool startSilent;

  @override
  State<YuanChuanApp> createState() => _YuanChuanAppState();
}

class _YuanChuanAppState extends State<YuanChuanApp> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState(
      startInFloatingBar: widget.startInFloatingBar,
      startSilent: widget.startSilent,
    )..init();
  }

  @override
  void dispose() {
    appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF087F8C);
    return ValueListenableBuilder<double>(
      valueListenable: appState.fontScaleNotifier,
      builder: (context, fontScale, _) => MaterialApp(
        title: '原传',
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          // 应用内字号覆盖系统超大字号，保证布局稳定；设置页可随时调整。
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(fontScale),
            ),
            child: child!,
          );
        },
        navigatorKey: navigatorKey,
        theme: ThemeData(
          useMaterial3: true,
          visualDensity: VisualDensity.standard,
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF5F7F8),
          textTheme: ThemeData.light().textTheme.apply(
                // Windows 明确使用雅黑 UI，避免中英文混排时字重、基线不一致。
                fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
                fontFamilyFallback: const [
                  'Microsoft YaHei',
                  'Noto Sans CJK SC',
                  'Noto Sans SC',
                  'sans-serif',
                ],
                bodyColor: const Color(0xFF1F2A2D),
                displayColor: const Color(0xFF1F2A2D),
              ),
          cardTheme: const CardThemeData(
            elevation: 0,
            color: Colors.white,
            margin: EdgeInsets.zero,
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
          ),
        ),
        home: AnimatedBuilder(
          animation: appState,
          builder: (context, _) {
            if (appState.startupError != null) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 48, color: Colors.red),
                        const SizedBox(height: 16),
                        const Text('应用启动失败', style: TextStyle(fontSize: 22)),
                        const SizedBox(height: 12),
                        SelectableText(appState.startupError!),
                      ],
                    ),
                  ),
                ),
              );
            }
            if (!appState.initialized) {
              return const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 20),
                      Text('正在启动局域网传输服务…'),
                    ],
                  ),
                ),
              );
            }
            final content = switch (appState.displayMode) {
              DisplayMode.bar =>
                Scaffold(body: FloatingBar(appState: appState)),
              DisplayMode.panel =>
                Scaffold(body: QuickPanel(appState: appState)),
              DisplayMode.full => HomePage(appState: appState),
            };
            if (!appState.isDesktop) return content;
            // 无边框窗口的原生命中测试在部分 Windows 环境下不包含缩放边框，
            // 用 Flutter 层透明手柄显式调用系统缩放，边缘一拖就能改变大小。
            return DragToResizeArea(resizeEdgeSize: 8, child: content);
          },
        ),
      ),
    );
  }
}
