import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Windows 系统托盘（通知区域）图标。
///
/// 在独立 isolate 内建仅消息隐藏窗口，用周期 Timer 泵 Win32 消息；
/// Timer 之间 Dart 事件循环可以自由运行，命令端口（tip/balloon/stop）
/// 因此能被即时处理——旧实现的阻塞 sleep 循环里命令永远收不到，
/// 托盘"退出"后图标也删不掉。事件通过 SendPort 回传：open / bar / exit。
class TrayService {
  TrayService._();

  static TrayService? _instance;
  static bool get supported => !kIsWeb && Platform.isWindows;
  static TrayService get instance => _instance ??= TrayService._();

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  StreamSubscription? _sub;
  void Function(String event)? _onEvent;
  bool _started = false;

  Future<bool> start(void Function(String event) onEvent,
      {String tooltip = '原传', String? iconPath}) async {
    if (!supported || _started) return _started;
    _onEvent = onEvent;
    _events = ReceivePort();
    final cmdPort = ReceivePort();
    _commands = cmdPort.sendPort;
    _sub = _events!.listen((m) {
      if (m is String) _onEvent?.call(m);
    });
    try {
      _isolate = await Isolate.spawn(_trayEntry, [
        _events!.sendPort,
        cmdPort.sendPort,
        tooltip,
        iconPath,
      ]);
      await cmdPort.first; // 等图标创建完成
      _started = true;
      return true;
    } catch (error) {
      debugPrint('托盘启动失败：$error');
      _cleanup();
      return false;
    }
  }

  void setTooltip(String text) => _commands?.send(['tip', text]);

  void setUnread(bool hasUnread, {String tooltip = '原传'}) =>
      setTooltip(hasUnread ? '$tooltip · 有新文件' : tooltip);

  /// 气泡提示：经 NIM_MODIFY 发送 NIF_INFO。
  void showBalloon(String message, {String title = '原传'}) =>
      _commands?.send(['balloon', title, message]);

  /// 停止托盘：等 isolate 删除图标并确认，再作为兜底强杀。
  Future<void> stop() async {
    if (!_started) {
      _cleanup();
      return;
    }
    final ack = ReceivePort();
    _commands?.send(['stop', ack.sendPort]);
    try {
      await ack.first.timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // isolate 卡住时由下面的 kill 兜底。
    }
    ack.close();
    _cleanup();
  }

  void _cleanup() {
    _sub?.cancel();
    _sub = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _events?.close();
    _events = null;
    _onEvent = null;
    _started = false;
  }
}

// ---- 以下代码运行在托盘 isolate 内 ----

const int _trayMsg = WM_APP + 1;
const int _idOpen = 1;
const int _idBar = 2;
const int _idExit = 3;
const int _trayIconId = 1;

int _hwnd = 0;
SendPort? _eventPort;
Pointer<NOTIFYICONDATA>? _nid;

void _trayEntry(List<dynamic> args) {
  _eventPort = args[0] as SendPort;
  final cmdPort = ReceivePort();
  (args[1] as SendPort).send('ready');
  final tip = args[2] as String;
  final iconPath = args.length > 3 ? args[3] as String? : null;

  final className = 'YuanChuanTray'.toNativeUtf16();
  final hInstance = GetModuleHandle(nullptr);
  final wc = calloc<WNDCLASS>();
  final wndProc = Pointer.fromFunction<WNDPROC>(_wndProc, 0);
  try {
    wc.ref.style = 0;
    wc.ref.lpfnWndProc = wndProc;
    wc.ref.cbClsExtra = 0;
    wc.ref.cbWndExtra = 0;
    wc.ref.hInstance = hInstance;
    wc.ref.hIcon = 0;
    wc.ref.hCursor = 0;
    wc.ref.hbrBackground = 0;
    wc.ref.lpszMenuName = nullptr;
    wc.ref.lpszClassName = className.cast();
    RegisterClass(wc);

    _hwnd = CreateWindowEx(
      0,
      className.cast(),
      nullptr,
      0,
      0,
      0,
      0,
      0,
      HWND_MESSAGE,
      0,
      hInstance,
      nullptr,
    );

    // 优先加载应用自带 ico；缺失或加载失败时回退系统默认图标。
    var hIcon = LoadIcon(0, IDI_APPLICATION);
    var loadedIcon = 0;
    if (iconPath != null && iconPath.isNotEmpty) {
      final path = iconPath.toNativeUtf16();
      try {
        final image = LoadImage(
          0,
          path,
          IMAGE_ICON,
          0,
          0,
          LR_LOADFROMFILE | LR_DEFAULTSIZE,
        );
        if (image != 0) {
          hIcon = image;
          loadedIcon = image;
        }
      } catch (_) {
        // 图标文件损坏时沿用系统默认。
      } finally {
        calloc.free(path);
      }
    }
    _nid = calloc<NOTIFYICONDATA>();
    _nid!.ref.cbSize = sizeOf<NOTIFYICONDATA>();
    _nid!.ref.hWnd = _hwnd;
    _nid!.ref.uID = _trayIconId;
    _nid!.ref.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    _nid!.ref.uCallbackMessage = _trayMsg;
    _nid!.ref.hIcon = hIcon;
    _nid!.ref.szTip = tip;
    Shell_NotifyIcon(NIM_ADD, _nid!);

    final msg = calloc<MSG>();
    var running = true;
    // 命令即时处理：Timer 泵消息之间事件循环是空闲的，
    // cmdPort 的监听回调因此总能运行（旧实现的 sleep 死循环收不到命令）。
    cmdPort.listen((cmd) {
      final list = cmd as List<dynamic>;
      switch (list[0] as String) {
        case 'tip':
          _nid!.ref.szTip = list[1] as String;
          Shell_NotifyIcon(NIM_MODIFY, _nid!);
          break;
        case 'balloon':
          _nid!.ref.szInfoTitle = list[1] as String;
          _nid!.ref.szInfo = list[2] as String;
          _nid!.ref.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_INFO;
          _nid!.ref.dwInfoFlags = NIIF_NONE;
          Shell_NotifyIcon(NIM_MODIFY, _nid!);
          break;
        case 'stop':
          running = false;
          final ack = list.length > 1 ? list[1] as SendPort? : null;
          // 先删图标、释放资源，再回执。
          Shell_NotifyIcon(NIM_DELETE, _nid!);
          if (loadedIcon != 0) DestroyIcon(loadedIcon);
          calloc.free(_nid!);
          _nid = null;
          if (_hwnd != 0) DestroyWindow(_hwnd);
          _hwnd = 0;
          ack?.send('stopped');
          break;
      }
    });
    final pump = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!running) {
        timer.cancel();
        return;
      }
      while (PeekMessage(msg, 0, 0, 0, PM_REMOVE) != 0) {
        TranslateMessage(msg);
        DispatchMessage(msg);
      }
    });
    // running 翻转由命令回调负责；这里只等它结束。
    Timer.periodic(const Duration(milliseconds: 50), (watch) {
      if (!running) {
        watch.cancel();
        pump.cancel();
        calloc.free(msg);
        calloc.free(className);
        calloc.free(wc);
        cmdPort.close();
      }
    });
  } catch (error) {
    // 托盘 isolate 内任何异常：尽量删图标后退出。
    if (_nid != null) {
      Shell_NotifyIcon(NIM_DELETE, _nid!);
      calloc.free(_nid!);
      _nid = null;
    }
    calloc.free(className);
    calloc.free(wc);
    cmdPort.close();
  }
}

int _wndProc(int hwnd, int msg, int wParam, int lParam) {
  if (msg == _trayMsg) {
    final event = lParam & 0xffffffff;
    if (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK) {
      _eventPort?.send('open');
    } else if (event == WM_RBUTTONUP) {
      _showMenu(hwnd);
    }
    return 0;
  }
  return DefWindowProc(hwnd, msg, wParam, lParam);
}

void _showMenu(int hwnd) {
  final menu = CreatePopupMenu();
  if (menu == 0) return;
  final open = '显示主界面'.toNativeUtf16();
  final bar = '显示悬浮条'.toNativeUtf16();
  final exit = '退出'.toNativeUtf16();
  try {
    AppendMenu(menu, MF_STRING, _idOpen, open.cast());
    AppendMenu(menu, MF_STRING, _idBar, bar.cast());
    AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenu(menu, MF_STRING, _idExit, exit.cast());
    final point = calloc<POINT>();
    try {
      GetCursorPos(point);
      SetForegroundWindow(hwnd);
      final picked = TrackPopupMenu(
        menu,
        TPM_RIGHTBUTTON,
        point.ref.x,
        point.ref.y,
        0,
        hwnd,
        nullptr,
      );
      PostMessage(hwnd, WM_NULL, 0, 0);
      if (picked == _idOpen) _eventPort?.send('open');
      if (picked == _idBar) _eventPort?.send('bar');
      if (picked == _idExit) _eventPort?.send('exit');
    } finally {
      calloc.free(point);
    }
  } finally {
    DestroyMenu(menu);
    calloc.free(open);
    calloc.free(bar);
    calloc.free(exit);
  }
}
