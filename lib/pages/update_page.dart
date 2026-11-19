// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// 新版本提示与下载安装对话框。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({required this.release, super.key});

  final ReleaseInfo release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0;
    });
    try {
      final path = await UpdateService.download(
        widget.release,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await UpdateService.install(
        path,
        expectedSha256: widget.release.sha256,
      );
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: Color(0xFF087F8C)),
          const SizedBox(width: 10),
          const Text('发现新版本'),
          const Spacer(),
          Text(appVersion,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('v${release.version}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              release.notes.isEmpty ? '修复问题与体验优化' : release.notes,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF54666B)),
            ),
            if (_downloading) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Text('下载中 ${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            const Text(
              'Windows 下载后会自动安装并重启；Android 会拉起系统安装器。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading
              ? null
              : () async {
                  await UpdateService.skip(release.version);
                  if (context.mounted) Navigator.of(context).pop();
                },
          child: const Text('本次跳过'),
        ),
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: _downloading ? null : _downloadAndInstall,
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}
