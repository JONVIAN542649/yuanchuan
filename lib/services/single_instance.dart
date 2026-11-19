import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 单实例锁：同名互斥量已存在说明原传已在运行。
///
/// 双开会导致 UDP/TCP 端口绑定失败与窗口状态错乱（曾表现为启动即崩），
/// 因此第二实例直接退出；锁随进程结束由系统释放，无需手动清理。
class SingleInstance {
  SingleInstance._();

  static const _mutexName = 'Local\\YuanChuan_SingleInstance_47653';
  static const _errorAlreadyExists = 183;

  /// 调用方须在 Platform.isWindows 为真时使用；其他平台恒返回 true。
  static bool acquire() {
    if (!Platform.isWindows) return true;
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final createMutex = kernel32.lookupFunction<
        ffi.Pointer Function(ffi.Pointer, ffi.Int32, ffi.Pointer<Utf16>),
        ffi.Pointer Function(ffi.Pointer, int, ffi.Pointer<Utf16>)>(
      'CreateMutexW',
    );
    final getLastError = kernel32
        .lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');
    final name = _mutexName.toNativeUtf16();
    final handle = createMutex(ffi.nullptr, 0, name);
    // GetLastError 必须紧跟 CreateMutexW 取：中间任何分配/释放都会洗掉错误码。
    final alreadyExists = getLastError() == _errorAlreadyExists;
    calloc.free(name);
    return handle.address != 0 && !alreadyExists;
  }
}
