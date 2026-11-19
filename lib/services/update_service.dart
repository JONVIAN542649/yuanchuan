import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 当前版本。发版时与交付包版本号保持一致。
const appVersion = '0.4.1';

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.assetUrl,
    required this.assetName,
    this.sha256,
  });

  final String version;
  final String notes;
  final String pageUrl;
  final String assetUrl;
  final String assetName;

  /// 期望的包体 SHA-256（小写 hex）；为空表示发布页未提供，拒绝自动覆盖安装。
  final String? sha256;
}

/// 应用内自更新：从 GitHub Releases 检查新版本、下载、校验哈希并安装。
///
/// 不引入 http/archive 等第三方包，避免改动 native assets 清单导致
/// Windows 打包触发 C++ 重编译。HTTP 用 dart:io HttpClient，
/// Windows 解压用系统自带 PowerShell Expand-Archive。
class UpdateService {
  UpdateService._();

  static const _channel = MethodChannel('local_file_drop/system');
  static const _repoKey = 'local_file_drop.update.repo';
  static const _skipKey = 'local_file_drop.update.skip';
  static const _lastCheckKey = 'local_file_drop.update.last_check';
  static const _checkInterval = Duration(hours: 6);

  static Future<String?> configuredRepo() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_repoKey)?.trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  static Future<void> setRepo(String repo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoKey, repo.trim());
  }

  static Future<bool> isSkipped(String version) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skipKey) == version;
  }

  static Future<void> skip(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skipKey, version);
  }

  static bool isNewerVersion(String candidate, String current) {
    List<int> parse(String value) => value
        .replaceFirst(RegExp(r'^v'), '')
        .split(RegExp(r'[+.\-]'))
        .take(3)
        .map((part) => int.tryParse(part) ?? 0)
        .toList()
      ..addAll(List.filled(3, 0));
    final a = parse(candidate);
    final b = parse(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  /// 从 GitHub asset 的 digest 字段或独立 `.sha256` 资源解析期望哈希。
  static String? parseAssetDigest(Object? digest) {
    if (digest is! String) return null;
    final trimmed = digest.trim().toLowerCase();
    final match = RegExp(r'(?:sha256:)?([a-f0-9]{64})').firstMatch(trimmed);
    return match?.group(1);
  }

  /// 从 `*.sha256` 文件正文解析（支持 `hex` 或 `hex  filename`）。
  static String? parseSha256FileBody(String body) {
    final match =
        RegExp(r'([a-fA-F0-9]{64})').firstMatch(body.trim().split('\n').first);
    return match?.group(1)?.toLowerCase();
  }

  /// 检查更新。未配置仓库或未到检查间隔时返回 null。
  static Future<ReleaseInfo?> check({bool force = false}) async {
    final repo = await configuredRepo();
    if (repo == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - last < _checkInterval.inMilliseconds) return null;
    await prefs.setInt(_lastCheckKey, now);

    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      );
      request.headers
        ..set('User-Agent', 'YuanChuan-Updater')
        ..set('Accept', 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final version =
          (json['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), '');
      if (version.isEmpty || !isNewerVersion(version, appVersion)) return null;

      final assets = (json['assets'] as List<dynamic>? ?? const []);
      final wanted = Platform.isAndroid ? '.apk' : '.zip';
      Map<String, dynamic>? picked;
      Map<String, dynamic>? shaAsset;
      for (final raw in assets) {
        if (raw is! Map<String, dynamic>) continue;
        final name = (raw['name'] as String? ?? '').toLowerCase();
        if (name.endsWith(wanted)) {
          picked = raw;
        }
        if (name.endsWith('$wanted.sha256') || name.endsWith('.sha256')) {
          shaAsset = raw;
        }
      }
      if (picked == null) return null;

      var digest = parseAssetDigest(picked['digest']);
      if (digest == null && shaAsset != null) {
        digest = await _downloadSha256Text(
          client,
          shaAsset['browser_download_url'] as String,
        );
      }
      // 正文里也允许写 `SHA256: <hex>`（发版说明）。
      digest ??= parseAssetDigest(json['body'] as String?);

      return ReleaseInfo(
        version: version,
        notes: json['body'] as String? ?? '',
        pageUrl: json['html_url'] as String? ?? '',
        assetUrl: picked['browser_download_url'] as String,
        assetName: picked['name'] as String,
        sha256: digest,
      );
    } catch (error) {
      debugPrint('检查更新失败：$error');
      return null;
    } finally {
      client.close();
    }
  }

  static Future<String?> _downloadSha256Text(
    HttpClient client,
    String url,
  ) async {
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'YuanChuan-Updater');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decoder.bind(response).join();
      return parseSha256FileBody(body);
    } catch (_) {
      return null;
    }
  }

  /// 下载更新包并校验 SHA-256，返回本地路径。
  static Future<String> download(
    ReleaseInfo release, {
    void Function(double progress)? onProgress,
  }) async {
    final expected = release.sha256?.toLowerCase();
    if (expected == null || expected.length != 64) {
      throw StateError('发布页未提供 SHA-256，已拒绝下载，以免覆盖安装被篡改的包');
    }

    final directory = Platform.isAndroid
        ? Directory('/storage/emulated/0/Download/YuanChuan')
        : await Directory.systemTemp.createTemp('yuanchuan-update-');
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, release.assetName));

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(release.assetUrl));
      request.headers.set('User-Agent', 'YuanChuan-Updater');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw StateError('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength;
      final sink = target.openWrite();
      final digestSink = AccumulatorSink<Digest>();
      final hashInput = sha256.startChunkedConversion(digestSink);
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          hashInput.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
        hashInput.close();
      }
      final actual = digestSink.events.single.toString();
      if (actual != expected) {
        try {
          await target.delete();
        } catch (_) {}
        throw StateError('更新包校验失败：SHA-256 不匹配，已删除下载文件');
      }
      return target.path;
    } finally {
      client.close();
    }
  }

  /// 安装更新。Windows 写一次性 PowerShell 脚本：等主进程退出后解压覆盖并重启。
  /// Android 走原生 FileProvider 拉起系统安装器。
  ///
  /// [expectedSha256] 会再次传入脚本，覆盖前复验文件哈希。
  static Future<void> install(
    String packagePath, {
    String? expectedSha256,
  }) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('installApk', {'path': packagePath});
      return;
    }
    if (!Platform.isWindows) return;
    final hash = expectedSha256?.toLowerCase();
    if (hash == null || hash.length != 64) {
      throw StateError('缺少校验哈希，已拒绝覆盖安装');
    }
    // 覆盖前再算一遍，防止下载后、安装前文件被替换。
    final actual = await sha256.bind(File(packagePath).openRead()).first;
    if (actual.toString() != hash) {
      throw StateError('安装前复验失败：SHA-256 不匹配');
    }
    final exe = File(Platform.resolvedExecutable);
    final targetDir = exe.parent.path;
    final script =
        File(p.join(Directory.systemTemp.path, 'yuanchuan_updater.ps1'));
    await script.writeAsString(_windowsUpdaterScript());
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        packagePath,
        targetDir,
        p.basename(exe.path),
        pid.toString(),
        hash,
      ],
      mode: ProcessStartMode.detached,
    );
  }

  static String _windowsUpdaterScript() => r'''
param([string]$Zip, [string]$Target, [string]$Exe, [int]$AppPid, [string]$ExpectedSha256)
$ErrorActionPreference = 'Stop'
if (-not $ExpectedSha256 -or $ExpectedSha256.Length -ne 64) {
  throw '缺少 ExpectedSha256，拒绝覆盖安装'
}
$actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
  throw "更新包哈希不匹配：$actual"
}
$ErrorActionPreference = 'SilentlyContinue'
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Process -Id $AppPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 200
}
$extract = Join-Path $env:TEMP 'yuanchuan_update_extract'
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $extract -Force
$src = $extract
$items = @(Get-ChildItem -Force $extract)
if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $src = $items[0].FullName }
Copy-Item -Path (Join-Path $src '*') -Destination $Target -Recurse -Force
Start-Process -FilePath (Join-Path $Target $Exe) -ArgumentList '--silent'
''';
}
