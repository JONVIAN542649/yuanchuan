import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AES-GCM 1MiB 加解密耗时（应用实际算法路径）', () async {
    final aes = AesGcm.with256bits();
    final key = await aes.newSecretKey();
    final chunk = Uint8List(1024 * 1024);
    final nonce = Uint8List(12);

    var watch = Stopwatch()..start();
    final boxes = <SecretBox>[];
    for (var i = 0; i < 16; i++) {
      boxes.add(await aes.encrypt(chunk,
          secretKey: key, nonce: nonce));
    }
    watch.stop();
    // ignore: avoid_print
    print('加密 16×1MiB: ${watch.elapsedMilliseconds}ms（均 ${(watch.elapsedMilliseconds / 16).toStringAsFixed(1)}ms/块）');

    watch = Stopwatch()..start();
    for (final box in boxes) {
      await aes.decrypt(box, secretKey: key);
    }
    watch.stop();
    // ignore: avoid_print
    print('解密 16×1MiB: ${watch.elapsedMilliseconds}ms（均 ${(watch.elapsedMilliseconds / 16).toStringAsFixed(1)}ms/块）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
