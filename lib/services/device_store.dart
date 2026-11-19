import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer_models.dart';

class DeviceStore extends ChangeNotifier {
  static const _storageKey = 'local_file_drop.trusted_devices';
  final Map<String, TrustedDevice> _devices = {};

  List<TrustedDevice> get devices => List.unmodifiable(_devices.values);

  TrustedDevice? byId(String id) => _devices[id];

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final value in list) {
        final device = TrustedDevice.fromJson(value as Map<String, dynamic>);
        _devices[device.id] = device;
      }
    } catch (_) {
      // 损坏的配置不应阻止应用启动；新配对会重新写入有效配置。
    }
  }

  Future<void> addOrUpdate(TrustedDevice device) async {
    final existing = _devices[device.id];
    if (existing != null && existing.publicKey != device.publicKey) {
      throw StateError('设备密钥发生变化，请先删除旧配对再重新扫码');
    }
    // 旧版本广播不带平台，或本次数据暂缺平台时，保留已识别到的平台。
    final merged = device.platform == 'unknown' && existing != null
        ? device.copyWith(platform: existing.platform)
        : device;
    _devices[device.id] = merged;
    await _save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _devices.remove(id);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _storageKey,
      jsonEncode(_devices.values.map((device) => device.toJson()).toList()),
    );
  }
}
