import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;
// 0.7.0 起旧 API 收进 legacy.dart；悬浮条/小窗仍基于这套经典接口，
// 升级到 nativeapi 之前整文件沿用 legacy（仅 deprecation 提示）。
// ignore_for_file: deprecated_member_use
import 'package:window_manager/legacy.dart';

import 'app_state.dart';

/// EnumWindows 回调要求顶层函数：先把目标 PID 存进全局，再枚举本进程可见窗口。
int _enumTargetPid = 0;
int _enumFoundHwnd = 0;

int _enumWindowsCallback(int hwnd, int lParam) {
  final owner = calloc<ffi.Uint32>();
  try {
    win32.GetWindowThreadProcessId(hwnd, owner);
    if (owner.value == _enumTargetPid && win32.IsWindowVisible(hwnd) != 0) {
      _enumFoundHwnd = hwnd;
      return 0;
    }
  } finally {
    calloc.free(owner);
  }
  return 1;
}

/// Windows 端窗口形态与剪贴板。
///
/// 单窗口三种形态：完整主窗口 / 夸克式小窗 / 置顶悬浮条。
/// 悬浮条拖动、位置记忆、红点复制所需的 Win32 细节都收在这里。
class WindowPresenter with WindowListener {
  WindowPresenter._();

  // 悬浮条贴近 Windows 搜索栏的轻量尺寸，可自由拉伸。
  static const _barSize = Size(236, 40);
  static const _barMinSize = Size(96, 32);
  static const _barMaxSize = Size(560, 180);
  static const _panelSize = Size(380, 520);
  static const _panelMinSize = Size(300, 360);
  static const _fullSize = Size(480, 720);
  static const _fullMinSize = Size(380, 560);
  static const _barXKey = 'local_file_drop.window.bar.x';
  static const _barYKey = 'local_file_drop.window.bar.y';
  static const _barWKey = 'local_file_drop.window.bar.w';
  static const _barHKey = 'local_file_drop.window.bar.h';
  static const _panelWKey = 'local_file_drop.window.panel.w';
  static const _panelHKey = 'local_file_drop.window.panel.h';
  static const _panelXKey = 'local_file_drop.window.panel.x';
  static const _panelYKey = 'local_file_drop.window.panel.y';
  static const _pinnedKey = 'local_file_drop.window.pinned';

  static WindowPresenter? _instance;
  static DisplayMode? _currentMode;
  static bool _pinned = false;
  static Timer? _positionSaveTimer;
  static Timer? _resizeSaveTimer;
  static int _cachedHwnd = 0;
  static VoidCallback? onCloseRequested;

  static bool get pinned => _pinned;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static Future<void> init() async {
    if (!supported || _instance != null) return;
    await windowManager.ensureInitialized();
    final preferences = await SharedPreferences.getInstance();
    _pinned = preferences.getBool(_pinnedKey) ?? false;
    _instance = WindowPresenter._();
    windowManager.addListener(_instance!);
  }

  /// 切换主窗置顶；悬浮条和小窗本身就始终置顶，不受此开关影响。
  static Future<void> setPinned(bool value) async {
    _pinned = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_pinnedKey, value);
    if (_currentMode == DisplayMode.full) {
      await windowManager.setAlwaysOnTop(value);
    }
  }

  /// 查找本进程可见顶层窗口句柄（Flutter 主窗口）。
  /// 切到托盘隐藏后窗口不可见，此时沿用上次句柄，避免位置/尺寸设置落空。
  static int _findFlutterWindow() {
    if (!Platform.isWindows) return 0;
    if (_cachedHwnd != 0 && win32.IsWindow(_cachedHwnd) != 0) {
      return _cachedHwnd;
    }
    _enumTargetPid = win32.GetCurrentProcessId();
    _enumFoundHwnd = 0;
    final pointer =
        ffi.Pointer.fromFunction<win32.WNDENUMPROC>(_enumWindowsCallback, 1);
    win32.EnumWindows(pointer, 0);
    if (_enumFoundHwnd != 0) _cachedHwnd = _enumFoundHwnd;
    return _enumFoundHwnd;
  }

  /// 把窗口坐标（物理像素）换算成 Flutter 逻辑坐标所需的缩放。
  static double _dpiScale(int hwnd) {
    final dpi = hwnd != 0 ? win32.GetDpiForWindow(hwnd) : 0;
    return dpi >= 96 ? dpi / 96.0 : 1.0;
  }

  /// 让系统标题栏走浅色（白色）配色：关闭沉浸深色、标题栏刷白、文字黑色、边框浅灰。
  /// Win10 1809+ 生效（35/36 仅 Win11，失败返回非 0 无副作用）。
  static void _applyLightCaption(int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return;
    final value = calloc<ffi.Uint32>();
    try {
      const sizeOfDword = 4;
      value.value = 0; // USE_IMMERSIVE_DARK_MODE = FALSE → 浅色标题栏
      win32.DwmSetWindowAttribute(hwnd, 20, value, sizeOfDword);
      value.value = 0x00FFFFFF; // COLORREF 白色标题栏（0x00BBGGRR）
      win32.DwmSetWindowAttribute(hwnd, 35, value, sizeOfDword);
      value.value = 0x00000000; // 标题文字黑色
      win32.DwmSetWindowAttribute(hwnd, 36, value, sizeOfDword);
      value.value = 0x00D9D9D9; // 窗口边框浅灰
      win32.DwmSetWindowAttribute(hwnd, 34, value, sizeOfDword);
    } finally {
      calloc.free(value);
    }
  }

  /// 形态切换是工具操作，不需要 DWM 的缩放/淡入过渡，否则会有明显拖影延迟。
  static void _disableTransitions(int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return;
    final value = calloc<ffi.Uint32>();
    try {
      value.value = 1;
      win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_TRANSITIONS_FORCEDISABLED,
        value,
        4,
      );
    } finally {
      calloc.free(value);
    }
  }

  /// 读取窗口物理坐标并换算为 Flutter 逻辑坐标。
  static ({double x, double y, double width, double height})? _windowBoundsDip(
      int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return null;
    final rect = calloc<win32.RECT>();
    try {
      if (win32.GetWindowRect(hwnd, rect) == 0) return null;
      final scale = _dpiScale(hwnd);
      return (
        x: rect.ref.left / scale,
        y: rect.ref.top / scale,
        width: (rect.ref.right - rect.ref.left) / scale,
        height: (rect.ref.bottom - rect.ref.top) / scale,
      );
    } finally {
      calloc.free(rect);
    }
  }

  /// 插件调用的尺寸接口是异步平台通道，连续切换时会出现肉眼可见的滞后。
  /// 这里在显示后用 Win32 再落一次最终边界，保证即时到位。
  static void _applyBoundsDirect(
    int hwnd,
    ({double x, double y, double width, double height}) bounds,
  ) {
    if (!Platform.isWindows || hwnd == 0) return;
    final scale = _dpiScale(hwnd);
    win32.SetWindowPos(
      hwnd,
      0,
      (bounds.x * scale).round(),
      (bounds.y * scale).round(),
      (bounds.width * scale).round(),
      (bounds.height * scale).round(),
      win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW,
    );
  }

  static double _screenWidthDip(int hwnd) =>
      win32.GetSystemMetrics(win32.SM_CXSCREEN) / _dpiScale(hwnd);

  static double _screenHeightDip(int hwnd) =>
      win32.GetSystemMetrics(win32.SM_CYSCREEN) / _dpiScale(hwnd);

  /// 可用工作区（排除任务栏），避免窗口底部导航被任务栏盖住。
  static ({double x, double y, double width, double height})? _workAreaDip(
      int hwnd) {
    if (!Platform.isWindows) return null;
    final rect = calloc<win32.RECT>();
    try {
      if (win32.SystemParametersInfo(
            win32.SPI_GETWORKAREA,
            0,
            rect.cast(),
            0,
          ) ==
          0) {
        return null;
      }
      final scale = _dpiScale(hwnd);
      return (
        x: rect.ref.left / scale,
        y: rect.ref.top / scale,
        width: (rect.ref.right - rect.ref.left) / scale,
        height: (rect.ref.bottom - rect.ref.top) / scale,
      );
    } finally {
      calloc.free(rect);
    }
  }

  static double _clampAxis(double value, double min, double max) {
    if (max < min) return min;
    return value < min ? min : (value > max ? max : value);
  }

  /// 计算三种形态的目标边界；悬浮条和小窗都会记住上次的位置与尺寸。
  static Future<({double x, double y, double width, double height})>
      _targetBounds(
    DisplayMode mode,
    int hwnd, {
    required bool restorePosition,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final work = _workAreaDip(hwnd);
    final areaX = work?.x ?? 0;
    final areaY = work?.y ?? 0;
    final areaW = work?.width ?? _screenWidthDip(hwnd);
    final areaH = work?.height ?? _screenHeightDip(hwnd);
    if (mode == DisplayMode.bar) {
      final maxWidth =
          _barMaxSize.width < areaW - 16 ? _barMaxSize.width : areaW - 16;
      final maxHeight =
          _barMaxSize.height < areaH - 16 ? _barMaxSize.height : areaH - 16;
      final width = (preferences.getDouble(_barWKey) ?? _barSize.width)
          .clamp(_barMinSize.width, maxWidth)
          .toDouble();
      final height = (preferences.getDouble(_barHKey) ?? _barSize.height)
          .clamp(_barMinSize.height, maxHeight)
          .toDouble();
      final x = _clampAxis(
        preferences.getDouble(_barXKey) ?? (areaX + areaW - width - 24),
        areaX + 8,
        areaX + areaW - width - 8,
      );
      final y = _clampAxis(
        preferences.getDouble(_barYKey) ?? (areaY + areaH - height - 24),
        areaY + 8,
        areaY + areaH - height - 8,
      );
      return (x: x, y: y, width: width, height: height);
    }
    if (mode == DisplayMode.panel) {
      final width = (preferences.getDouble(_panelWKey) ?? _panelSize.width)
          .clamp(_panelMinSize.width, areaW - 32)
          .toDouble();
      final height = (preferences.getDouble(_panelHKey) ?? _panelSize.height)
          .clamp(_panelMinSize.height, areaH - 32)
          .toDouble();
      final x = _clampAxis(
        preferences.getDouble(_panelXKey) ?? (areaX + areaW - width - 24),
        areaX + 8,
        areaX + areaW - width - 8,
      );
      final y = _clampAxis(
        preferences.getDouble(_panelYKey) ?? (areaY + areaH - height - 24),
        areaY + 8,
        areaY + areaH - height - 8,
      );
      return (x: x, y: y, width: width, height: height);
    }
    final current = _windowBoundsDip(hwnd);
    final width = restorePosition
        ? (_fullSize.width < areaW - 32 ? _fullSize.width : areaW - 32)
        : (current?.width ?? _fullSize.width);
    final height = restorePosition
        ? (_fullSize.height < areaH - 32 ? _fullSize.height : areaH - 32)
        : (current?.height ?? _fullSize.height);
    return (
      x: restorePosition
          ? areaX + (areaW - width) / 2
          : (current?.x ?? areaX + 40),
      y: restorePosition
          ? areaY + (areaH - height) / 2
          : (current?.y ?? areaY + 40),
      width: width,
      height: height,
    );
  }

  static Future<void> applyMode(DisplayMode mode,
      {bool restorePosition = false}) async {
    if (!supported) return;
    final hwnd = _findFlutterWindow();
    // 同形态只恢复显示，不重复重建标题栏/尺寸，避免无意义的系统动画。
    if (_currentMode == mode) {
      await windowManager.show();
      if (mode != DisplayMode.bar) await windowManager.focus();
      _applyLightCaption(hwnd);
      _disableTransitions(hwnd);
      return;
    }
    _currentMode = mode;
    try {
      final target = await _targetBounds(
        mode,
        hwnd,
        restorePosition: restorePosition,
      );
      switch (mode) {
        case DisplayMode.bar:
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          await windowManager.setAlwaysOnTop(true);
          await windowManager.setSkipTaskbar(true);
          await windowManager.setResizable(true);
          await windowManager.setMinimumSize(_barMinSize);
          await windowManager.setMaximumSize(_barMaxSize);
          break;
        case DisplayMode.panel:
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          await windowManager.setAlwaysOnTop(true);
          await windowManager.setSkipTaskbar(false);
          await windowManager.setResizable(true);
          await windowManager.setMinimumSize(_panelMinSize);
          await windowManager.setMaximumSize(const Size(10000, 10000));
          break;
        case DisplayMode.full:
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
          await windowManager.setAlwaysOnTop(_pinned);
          await windowManager.setSkipTaskbar(false);
          await windowManager.setResizable(true);
          await windowManager.setMinimumSize(_fullMinSize);
          await windowManager.setMaximumSize(const Size(10000, 10000));
          break;
      }
      await windowManager.setSize(Size(target.width, target.height));
      await windowManager.setPosition(Offset(target.x, target.y));
      await windowManager.show();
      if (mode != DisplayMode.bar) {
        await windowManager.focus();
      }
      // 启动阶段窗口可能尚未可见，前面找不到句柄；显示后重新取一次，
      // 确保尺寸、位置、白色标题栏真正落到主窗口上。
      final visibleHwnd = _findFlutterWindow();
      // 平台通道是异步的；再用原生一次落最终边界，形态切换即时到位。
      _applyBoundsDirect(visibleHwnd, target);
      // setTitleBarStyle/show 会重建或覆盖非客户区配色，必须在显示后再刷白。
      _applyLightCaption(visibleHwnd);
      _disableTransitions(visibleHwnd);
      // 插件在 Windows 上还有异步收尾，再补一次避免偶发被深色主题覆盖。
      Timer(const Duration(milliseconds: 120), () {
        if (_currentMode == mode) {
          final currentHwnd = _findFlutterWindow();
          _applyBoundsDirect(currentHwnd, target);
          _applyLightCaption(currentHwnd);
          _disableTransitions(currentHwnd);
        }
      });
    } catch (error) {
      // 窗口插件偶发失败不应拖垮传输服务；保持当前形态继续运行。
      debugPrint('窗口形态切换失败（$mode）：$error');
    }
  }

  /// 拦截窗口关闭按钮：点 X 时不退出，由上层决定隐藏到托盘。
  static Future<void> setPreventClose(bool prevent) =>
      windowManager.setPreventClose(prevent);

  /// 从托盘恢复：显示并置前。
  static Future<void> showAndFocus() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// 真正退出：解除拦截后强制关闭窗口。
  static Future<void> forceClose() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// 隐藏到托盘（窗口仍在，服务继续运行）。
  static Future<void> hideToTray() => windowManager.hide();

  /// 拖动窗口：直接投递系统非客户区拖动消息，不再走一遍平台通道。
  static Future<void> startDragging() async {
    if (!Platform.isWindows) return windowManager.startDragging();
    final hwnd = _findFlutterWindow();
    if (hwnd == 0) return windowManager.startDragging();
    win32.ReleaseCapture();
    win32.PostMessage(
      hwnd,
      win32.WM_SYSCOMMAND,
      win32.SC_MOVE | win32.HTCAPTION,
      0,
    );
  }

  @override
  void onWindowClose() {
    // setPreventClose(true) 时点 X 会触发本回调但窗口不关闭，
    // 由上层决定隐藏到托盘（而非退出）。
    onCloseRequested?.call();
  }

  @override
  void onWindowMove() {
    final mode = _currentMode;
    if (mode != DisplayMode.bar && mode != DisplayMode.panel) return;
    // 拖动过程中事件极密，合并到 250ms 后统一落盘。
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer(const Duration(milliseconds: 250), () async {
      final bounds = _windowBoundsDip(_findFlutterWindow());
      if (bounds == null) return;
      final preferences = await SharedPreferences.getInstance();
      if (mode == DisplayMode.bar) {
        await preferences.setDouble(_barXKey, bounds.x);
        await preferences.setDouble(_barYKey, bounds.y);
      } else {
        await preferences.setDouble(_panelXKey, bounds.x);
        await preferences.setDouble(_panelYKey, bounds.y);
      }
    });
  }

  @override
  void onWindowResize() {
    final mode = _currentMode;
    if (mode != DisplayMode.bar && mode != DisplayMode.panel) return;
    // 缩放事件合并落盘，避免拖拽时高频写磁盘。
    _resizeSaveTimer?.cancel();
    _resizeSaveTimer = Timer(const Duration(milliseconds: 250), () async {
      final bounds = _windowBoundsDip(_findFlutterWindow());
      if (bounds == null) return;
      final preferences = await SharedPreferences.getInstance();
      if (mode == DisplayMode.bar) {
        await preferences.setDouble(_barWKey, bounds.width);
        await preferences.setDouble(_barHKey, bounds.height);
      } else {
        await preferences.setDouble(_panelWKey, bounds.width);
        await preferences.setDouble(_panelHKey, bounds.height);
      }
    });
  }

  /// 把一组本地文件路径放入剪贴板（CF_HDROP），
  /// 在资源管理器 Ctrl+V 即可粘贴任意数量、任意类型的文件。
  static Future<void> copyFilesToClipboard(List<String> paths) async {
    if (!Platform.isWindows || paths.isEmpty) return;
    final hwnd = _findFlutterWindow();
    if (win32.OpenClipboard(hwnd) == 0) {
      throw StateError('剪贴板暂不可用，请稍后重试');
    }
    final codeUnits = <int>[];
    for (final path in paths) {
      codeUnits.addAll(path.codeUnits);
      codeUnits.add(0);
    }
    codeUnits.add(0);
    // DROPFILES 固定 20 字节（pFiles/pt/fNC/fWide），后接 UTF-16 路径与双终止符。
    const dropFilesBytes = 20;
    final totalBytes = dropFilesBytes + codeUnits.length * 2;
    var hGlobal = ffi.Pointer.fromAddress(0);
    try {
      win32.EmptyClipboard();
      hGlobal = win32.GlobalAlloc(win32.GMEM_MOVEABLE, totalBytes);
      if (hGlobal.address == 0) {
        throw StateError('分配剪贴板内存失败');
      }
      final locked = win32.GlobalLock(hGlobal);
      final header = ffi.Pointer<win32.DROPFILES>.fromAddress(locked.address);
      header.ref.pFiles = dropFilesBytes;
      header.ref.pt.x = 0;
      header.ref.pt.y = 0;
      header.ref.fNC = 0;
      header.ref.fWide = 1;
      final cursor =
          ffi.Pointer<ffi.Uint16>.fromAddress(locked.address + dropFilesBytes);
      for (var index = 0; index < codeUnits.length; index++) {
        cursor[index] = codeUnits[index];
      }
      win32.GlobalUnlock(hGlobal);
      final placed = win32.SetClipboardData(win32.CF_HDROP, hGlobal.address);
      if (placed == 0) {
        throw StateError('写入剪贴板失败');
      }
      hGlobal = ffi.Pointer.fromAddress(0); // 所有权已移交系统。
    } finally {
      win32.CloseClipboard();
      if (hGlobal.address != 0) {
        win32.GlobalFree(hGlobal);
      }
    }
  }
}
