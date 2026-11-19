import 'dart:async';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_state.dart';
import '../services/relay_service.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({required this.appState, super.key});

  final AppState appState;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool handling = false;
  String? error;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (handling) return;
    final raw =
        capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null) return;
    setState(() {
      handling = true;
      error = null;
    });
    try {
      await widget.appState.pairFromQr(raw);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('配对成功，以后启动会自动连接')));
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '$exception';
        handling = false;
      });
    }
  }

  void _openManualEntry() {
    controller.stop();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => ManualPairPage(appState: widget.appState),
        ))
        .then((_) => controller.start());
  }

  @override
  void dispose() {
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描电脑配对码')),
      body: Stack(
        children: [
          MobileScanner(controller: controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black87,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    handling ? '正在安全配对…' : '将二维码放入取景框',
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!,
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    style:
                        OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    onPressed: _openManualEntry,
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    label: const Text('扫不了码？手动输入设备码'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备码配对：手动填电脑 IP、端口和 6 位设备码（电脑“显示配对码”弹窗里都有）。
/// 两端不在同一网络时可保留中继地址（默认已填自建中继），手机流量也能配对。
class ManualPairPage extends StatefulWidget {
  const ManualPairPage({required this.appState, super.key});

  final AppState appState;

  @override
  State<ManualPairPage> createState() => _ManualPairPageState();
}

class _ManualPairPageState extends State<ManualPairPage> {
  final hostController = TextEditingController();
  final portController = TextEditingController(text: '47654');
  final codeController = TextEditingController();
  final relayController =
      TextEditingController(text: RelayService.defaultRelayAddress);
  bool pairing = false;
  String? error;

  @override
  void dispose() {
    hostController.dispose();
    portController.dispose();
    codeController.dispose();
    relayController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final port = int.tryParse(portController.text.trim());
    setState(() {
      pairing = true;
      error = null;
    });
    try {
      await widget.appState.pairWithCode(
        hostController.text,
        port ?? 0,
        codeController.text,
        relay: relayController.text,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('配对成功，以后启动会自动连接')));
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '$exception';
        pairing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设备码配对')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '电脑“设备 → 显示配对码”弹窗里有 6 位设备码和电脑地址。'
                  '同一 Wi-Fi/热点下直连；不在同一网络时保留下方中继地址即可走流量配对。',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: hostController,
                  decoration: const InputDecoration(
                    labelText: '电脑 IP',
                    hintText: '例如 192.168.1.5',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  decoration: const InputDecoration(labelText: '端口'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                    labelText: '6 位设备码',
                    hintText: '电脑弹窗中显示',
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: relayController,
                  decoration: const InputDecoration(
                    labelText: '中继（跨网时使用）',
                    helperText: '同一网络下可清空；跨网保持默认即可',
                  ),
                  keyboardType: TextInputType.url,
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: pairing ? null : _submit,
                  child: Text(pairing ? '正在配对…' : '配对'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
