import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String randomId([int length = 16]) {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(length, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

List<int> randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.name,
    required this.keyPair,
    required this.publicKey,
  });

  final String id;
  final String name;
  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  String get publicKeyBase64 => base64Encode(publicKey);

  static Future<DeviceIdentity> generate(String name, {String? id}) async {
    final keyPair = await X25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return DeviceIdentity(
      id: id ?? randomId(),
      name: name,
      keyPair: keyPair,
      publicKey: publicKey.bytes,
    );
  }

  Future<List<int>> privateBytes() async {
    final key = await keyPair.extract();
    return key.bytes;
  }

  Future<SecretKey> sharedSecret(List<int> remotePublicKey) {
    return X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        remotePublicKey,
        type: KeyPairType.x25519,
      ),
    );
  }
}

class IdentityService {
  IdentityService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _privateKeyName = 'local_file_drop.private_key';
  static const _publicKeyName = 'local_file_drop.public_key';
  static const _deviceIdName = 'local_file_drop.device_id';
  static const _deviceNameName = 'local_file_drop.device_name';

  final FlutterSecureStorage _secureStorage;
  late DeviceIdentity identity;

  Future<DeviceIdentity> load() async {
    final preferences = await SharedPreferences.getInstance();
    final privateBase64 = await _secureStorage.read(key: _privateKeyName);
    final publicBase64 = await _secureStorage.read(key: _publicKeyName);
    final id = preferences.getString(_deviceIdName);
    if (privateBase64 != null && publicBase64 != null && id != null) {
      final keyPair =
          await X25519().newKeyPairFromSeed(base64Decode(privateBase64));
      final actualPublic = await keyPair.extractPublicKey();
      if (!const ListEquality<int>()
          .equals(actualPublic.bytes, base64Decode(publicBase64))) {
        throw StateError('本机密钥校验失败，请清除应用数据后重试');
      }
      identity = DeviceIdentity(
        id: id,
        name: preferences.getString(_deviceNameName) ?? Platform.localHostname,
        keyPair: keyPair,
        publicKey: actualPublic.bytes,
      );
      return identity;
    }

    identity = await DeviceIdentity.generate(
      preferences.getString(_deviceNameName) ?? Platform.localHostname,
    );
    await _secureStorage.write(
      key: _privateKeyName,
      value: base64Encode(await identity.privateBytes()),
    );
    await _secureStorage.write(
      key: _publicKeyName,
      value: identity.publicKeyBase64,
    );
    await preferences.setString(_deviceIdName, identity.id);
    await preferences.setString(_deviceNameName, identity.name);
    return identity;
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_deviceNameName, trimmed);
    identity = DeviceIdentity(
      id: identity.id,
      name: trimmed,
      keyPair: identity.keyPair,
      publicKey: identity.publicKey,
    );
  }
}

class ListEquality<T> {
  const ListEquality();

  bool equals(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
