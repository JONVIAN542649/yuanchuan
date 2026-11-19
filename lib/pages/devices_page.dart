import 'dart:async';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transfer_models.dart';
import '../services/app_state.dart';
import 'chat_page.dart';
import 'scanner_page.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({required this.appState, super.key});

  final AppState appState;

  Future<void> _showPairingQr(BuildContext context) async {
    try {
      final offer = await appState.beginPairing();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('配对新设备'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: QrImageView(
                      data: offer.qrPayload,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                      appState.gateway.isAndroid
                          ? '电脑端“设备 → 显示配对码”，把 6 位设备码填进去即连。\n二维码和设备码 5 分钟内有效，配对只需一次。'
                          : '手机端“设备 → 扫码配对”，扫码即连。\n二维码和设备码 5 分钟内有效，配对只需一次。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (offer.relay != null) ...[
                    const SizedBox(height: 8),
                    const Text('已启用跨网中继：手机用流量（不在同一网络）扫码也能配对和传输，速度受本机上行带宽限制。',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF087F8C))),
                  ],
                  if (!appState.gateway.isAndroid) ...[
                    _ReverseCodeEntry(appState: appState),
                  ],
                  const Divider(height: 28),
                  const Text('扫不了码？改用设备码配对',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Center(
                    child: SelectableText(
                      offer.deviceCode,
                      style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('手机端“扫码配对 → 手动输入设备码”，填入以下地址和上面的 6 位设备码：',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  SelectableText(
                    '${offer.hosts.join(' 或 ')}，端口 ${offer.port}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final clipboard = StringBuffer()
                        ..writeln('设备码：${offer.deviceCode}')
                        ..writeln('地址：${offer.hosts.join(' 或 ')}')
                        ..writeln('端口：${offer.port}');
                      await Clipboard.setData(
                          ClipboardData(text: clipboard.toString()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('配对信息已复制')));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制配对信息'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
          ],
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _scan(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ScannerPage(appState: appState),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final devices = appState.devices;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 480;
                          final avatar = CircleAvatar(
                            radius: compact ? 22 : 26,
                            backgroundColor:
                                Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(
                              appState.gateway.isAndroid
                                  ? Icons.smartphone
                                  : Icons.devices,
                              size: compact ? 22 : 26,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                          );
                          final details = Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  appState.identityService.identity.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  '局域网服务已启动 · 文件不经过云端',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      color: Color(0xFF5A6A70)),
                                ),
                              ],
                            ),
                          );
                          final action = appState.gateway.isAndroid
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 11),
                                        textStyle: const TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600),
                                      ),
                                      onPressed: () => _scan(context),
                                      icon: const Icon(Icons.qr_code_scanner,
                                          size: 19),
                                      label: const Text('扫码配对'),
                                    ),
                                    // PairDrop 式双向：手机也能亮码，让电脑凭码配对。
                                    TextButton.icon(
                                      onPressed: () => _showPairingQr(context),
                                      icon: const Icon(Icons.qr_code, size: 17),
                                      label: const Text('本机显示配对码'),
                                    ),
                                  ],
                                )
                              : FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 11),
                                    textStyle: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  onPressed: () => _showPairingQr(context),
                                  icon: const Icon(Icons.qr_code, size: 19),
                                  label: const Text('显示配对码'),
                                );
                          if (compact) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    avatar,
                                    const SizedBox(width: 12),
                                    details,
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: action),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              avatar,
                              const SizedBox(width: 16),
                              details,
                              const SizedBox(width: 16),
                              action,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('信任设备',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2A2D))),
                  const SizedBox(height: 12),
                  if (devices.isEmpty)
                    const Card(
                      child: Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 24, vertical: 44),
                        child: Column(
                          children: [
                            Icon(Icons.link_outlined,
                                size: 48, color: Color(0xFF9AA7AB)),
                            SizedBox(height: 16),
                            Text('还没有配对设备',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF37474F))),
                            SizedBox(height: 8),
                            Text('电脑显示二维码，手机扫一次；以后打开应用就会自动连接。',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12.5, color: Color(0xFF5A6A70))),
                          ],
                        ),
                      ),
                    )
                  else
                    ...devices.map((device) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child:
                              _DeviceCard(device: device, appState: appState),
                        )),
                ],
              ),
            ),
            _ChatComposer(appState: appState),
          ],
        ),
      ),
    );
  }
}

class _ChatComposer extends StatefulWidget {
  const _ChatComposer({required this.appState});

  final AppState appState;

  @override
  State<_ChatComposer> createState() => _ChatComposerState();
}

enum _AttachmentKind { image, file }

class _ChatComposerState extends State<_ChatComposer> {
  final _controller = TextEditingController();
  String? _targetId;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  DiscoveredDevice? _targetFor(List<DiscoveredDevice> devices) {
    if (devices.isEmpty) return null;
    for (final device in devices) {
      if (device.device.id == _targetId) return device;
    }
    for (final device in devices) {
      if (device.online) return device;
    }
    return devices.first;
  }

  Future<void> _sendText(DiscoveredDevice device) async {
    final text = _controller.text;
    if (text.isEmpty) return;
    _controller.clear();
    unawaited(widget.appState.sendText(device, text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已发送给 ${device.device.name}')),
      );
    }
  }

  Future<void> _openAttachments(DiscoveredDevice device) async {
    final kind = await showModalBottomSheet<_AttachmentKind>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: Color(0xFF087F8C)),
              title: const Text('图片'),
              subtitle: const Text('选择一张或多张照片，原图发送'),
              onTap: () => Navigator.pop(sheetContext, _AttachmentKind.image),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file, color: Color(0xFF087F8C)),
              title: const Text('文件'),
              subtitle: const Text('选择手机或电脑中的文件'),
              onTap: () => Navigator.pop(sheetContext, _AttachmentKind.file),
            ),
          ],
        ),
      ),
    );
    if (kind == null) return;
    if (kind == _AttachmentKind.image) {
      await widget.appState.sendImages(device);
    } else {
      await widget.appState.sendFiles(device);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.appState.devices;
    final target = _targetFor(devices);
    if (target != null && _targetId != target.device.id) {
      _targetId = target.device.id;
    }
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE3E9EA))),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 4),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (devices.length > 1)
                Row(
                  children: [
                    const Text('发送给',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF5A6A70))),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _targetId,
                        isDense: true,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF087F8C)),
                        items: [
                          for (final device in devices)
                            DropdownMenuItem(
                              value: device.device.id,
                              child: Text(
                                '${device.device.name}${device.online ? '' : '（离线）'}',
                              ),
                            ),
                        ],
                        onChanged: (id) => setState(() => _targetId = id),
                      ),
                    ),
                  ],
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: target != null,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF3F6F7),
                        hintText: target == null
                            ? '先配对设备，再发送文字或文件'
                            : '发送给 ${target.device.name}…',
                        hintStyle: const TextStyle(
                            fontSize: 13, color: Color(0xFF87979C)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RoundComposerButton(
                    tooltip: '添加文件或图片',
                    enabled: target != null,
                    background: const Color(0xFFE4F1F2),
                    foreground: const Color(0xFF087F8C),
                    glyph: '＋',
                    onPressed:
                        target == null ? null : () => _openAttachments(target),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox.shrink();
                      return Row(
                        children: [
                          const SizedBox(width: 6),
                          _RoundComposerButton(
                            tooltip: '发送文字',
                            enabled: target != null,
                            background: const Color(0xFF087F8C),
                            foreground: Colors.white,
                            glyph: '↑',
                            onPressed:
                                target == null ? null : () => _sendText(target),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundComposerButton extends StatelessWidget {
  const _RoundComposerButton({
    required this.tooltip,
    required this.enabled,
    required this.background,
    required this.foreground,
    required this.glyph,
    required this.onPressed,
  });

  final String tooltip;
  final bool enabled;
  final Color background;
  final Color foreground;
  final String glyph;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? background : const Color(0xFFE9EDEE),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: Text(
                glyph,
                style: TextStyle(
                  fontSize: 23,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: enabled ? foreground : const Color(0xFF9AA7AB),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.appState});

  final DiscoveredDevice device;
  final AppState appState;

  IconData _deviceIcon() {
    final platform = appState.deviceStore.byId(device.device.id)?.platform ??
        device.device.platform;
    return switch (platform) {
      'android' || 'ios' => Icons.smartphone,
      'windows' || 'macos' || 'linux' => Icons.devices,
      // 旧配对记录没有平台字段：以本机平台反推对端，电脑对手机、手机对电脑。
      _ => appState.isDesktop ? Icons.smartphone : Icons.devices,
    };
  }

  @override
  Widget build(BuildContext context) {
    final online = device.online;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ChatPage(appState: appState),
          ));
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(_deviceIcon(), size: 30, color: const Color(0xFF37474F)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.device.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.3),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          online ? '在线 · 可原样互传' : '离线 · 可选择文件，上线后自动传输',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: online
                                  ? Colors.green.shade700
                                  : const Color(0xFF5A6A70)),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ChatPage(appState: appState),
                      ));
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('聊天', style: TextStyle(fontSize: 12.5)),
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? Colors.green : Colors.grey),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面端反向配对：对方（手机）显示 6 位设备码，填入即配对。
/// 局域网内自动尝试广播见过的地址；跨网自动走中继配对房间。
class _ReverseCodeEntry extends StatefulWidget {
  const _ReverseCodeEntry({required this.appState});

  final AppState appState;

  @override
  State<_ReverseCodeEntry> createState() => _ReverseCodeEntryState();
}

class _ReverseCodeEntryState extends State<_ReverseCodeEntry> {
  final controller = TextEditingController();
  bool pairing = false;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      pairing = true;
      error = null;
    });
    try {
      await widget.appState.pairByCodeOnly(controller.text);
      if (!mounted) return;
      // 该输入框就嵌在配对弹窗里，只需关掉这一层。
      Navigator.of(context).pop();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 28),
        const Text('对方显示配对码？直接输入它的 6 位设备码',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '对方的 6 位设备码'),
          onSubmitted: (_) {
            if (!pairing) _submit();
          },
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
        ],
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: pairing ? null : _submit,
          icon: const Icon(Icons.key, size: 16),
          label: Text(pairing ? '正在配对…' : '凭设备码配对'),
        ),
      ],
    );
  }
}
