import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 内容指纹：稳定、跨进程可复现，避免 `String.hashCode` 的进程内不稳定与碰撞。
String contentHash(String text) => sha256.convert(utf8.encode(text)).toString();

/// 剪贴板去重键：只存哈希，不落盘明文。
String clipboardDedupKey(String text) => 't:${contentHash(text)}';
