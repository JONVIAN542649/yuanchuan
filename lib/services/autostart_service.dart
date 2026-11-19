import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

/// 开机启动形态。
enum StartupMode {
  silent('静默驻托盘', '--silent'),
  floating('显示悬浮条', '--floating'),
  full('显示主界面', '');

  const StartupMode(this.label, this.argument);

  final String label;
  final String argument;
}

/// Windows 开机自启动：写当前用户注册表 Run 键。
/// 只改 HKCU，不需要管理员权限；卸载/关闭开关即删除键值。
/// 启动形态（静默/悬浮条/主界面）可在设置里切换，写键时重新生成命令。
class AutostartService {
  AutostartService._();

  static const _runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'YuanChuan';
  static const _modeKey = 'local_file_drop.startup.mode';

  static bool get supported => !kIsWeb && Platform.isWindows;

  static Future<StartupMode> currentMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_modeKey) ?? StartupMode.silent.name;
    return StartupMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => StartupMode.silent,
    );
  }

  static Future<void> setMode(StartupMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  static Future<String> _command() async {
    final exe = Platform.resolvedExecutable;
    final argument = (await currentMode()).argument;
    return argument.isEmpty ? '"$exe"' : '"$exe" $argument';
  }

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    final key = calloc<ffi.IntPtr>();
    final subKey = _runKeyPath.toNativeUtf16();
    final name = _valueName.toNativeUtf16();
    final buffer = calloc<ffi.Uint8>(2048);
    final size = calloc<ffi.Uint32>()..value = 2048;
    try {
      if (win32.RegOpenKeyEx(
            win32.HKEY_CURRENT_USER,
            subKey,
            0,
            win32.KEY_QUERY_VALUE,
            key,
          ) !=
          win32.ERROR_SUCCESS) {
        return false;
      }
      final handle = key.value;
      final status = win32.RegQueryValueEx(
          handle, name, ffi.nullptr, ffi.nullptr, buffer, size);
      win32.RegCloseKey(handle);
      return status == win32.ERROR_SUCCESS;
    } finally {
      calloc
        ..free(key)
        ..free(subKey)
        ..free(name)
        ..free(buffer)
        ..free(size);
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
    final key = calloc<ffi.IntPtr>();
    final subKey = _runKeyPath.toNativeUtf16();
    final name = _valueName.toNativeUtf16();
    try {
      if (win32.RegOpenKeyEx(
              win32.HKEY_CURRENT_USER, subKey, 0, win32.KEY_SET_VALUE, key) !=
          win32.ERROR_SUCCESS) {
        throw StateError('无法打开注册表 Run 键');
      }
      final handle = key.value;
      if (enabled) {
        final commandText = await _command();
        final command = commandText.toNativeUtf16();
        try {
          // UTF-16 编码字节数 + 结束符。
          final bytes = (commandText.length + 1) * 2;
          final status = win32.RegSetValueEx(
            handle,
            name,
            0,
            win32.REG_SZ,
            command.cast<ffi.Uint8>(),
            bytes,
          );
          if (status != win32.ERROR_SUCCESS) {
            throw StateError('写入自启动项失败（$status）');
          }
        } finally {
          calloc.free(command);
        }
      } else {
        final status = win32.RegDeleteValue(handle, name);
        if (status != win32.ERROR_SUCCESS &&
            status != win32.ERROR_FILE_NOT_FOUND) {
          throw StateError('删除自启动项失败（$status）');
        }
      }
      win32.RegCloseKey(handle);
    } finally {
      calloc
        ..free(key)
        ..free(subKey)
        ..free(name);
    }
  }
}
