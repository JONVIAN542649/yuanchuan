import 'dart:async';

// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/autostart_service.dart';
import '../services/update_service.dart';
import 'update_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.appState, super.key});

  final AppState appState;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  late final TextEditingController nameController;
  late final TextEditingController repoController;
  bool? _autostartEnabled;
  StartupMode _startupMode = StartupMode.silent;
  bool _checkingUpdate = false;
  bool _floatingEnabled = false;
  bool _bootAutostart = false;
  bool _awaitingOverlayPermission = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(
        text: widget.appState.identityService.identity.name);
    repoController = TextEditingController();
    WidgetsBinding.instance.addObserver(this);
    _loadAutostart();
    _loadUpdateRepo();
    _loadMobileOptions();
  }

  Future<void> _loadMobileOptions() async {
    if (!widget.appState.gateway.isAndroid) return;
    final results = await Future.wait([
      widget.appState.gateway.isFloatingWindowEnabled(),
      widget.appState.gateway.isBootAutostartEnabled(),
    ]);
    var floating = results[0];
    if (_awaitingOverlayPermission &&
        await widget.appState.gateway.hasOverlayPermission()) {
      await widget.appState.gateway.setFloatingWindow(true);
      floating = true;
      _awaitingOverlayPermission = false;
    }
    if (mounted) {
      setState(() {
        _floatingEnabled = floating;
        _bootAutostart = results[1];
      });
    }
  }

  Future<void> _toggleFloatingWindow(bool value) async {
    final gateway = widget.appState.gateway;
    try {
      if (value) {
        final granted = await gateway.hasOverlayPermission();
        if (!granted) {
          _awaitingOverlayPermission = true;
          await gateway.requestOverlayPermission();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('请在系统页面允许“显示在其他应用上层”，返回后再打开开关'),
            ));
          }
          return;
        }
        await gateway.setFloatingWindow(true);
      } else {
        await gateway.setFloatingWindow(false);
      }
      if (mounted) setState(() => _floatingEnabled = value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _toggleBootAutostart(bool value) async {
    try {
      await widget.appState.gateway.setBootAutostart(value);
      if (mounted) {
        setState(() => _bootAutostart = value);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value ? '已开启开机后台启动，如系统拦截请在手机设置中允许原传自启动' : '已关闭开机后台启动'),
        ));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _loadUpdateRepo() async {
    final repo = await UpdateService.configuredRepo();
    if (mounted) repoController.text = repo ?? '';
  }

  Future<void> _checkUpdate() async {
    final repo = repoController.text.trim();
    if (repo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 GitHub 仓库（格式 owner/repo）')),
      );
      return;
    }
    setState(() => _checkingUpdate = true);
    try {
      await UpdateService.setRepo(repo);
      final release = await UpdateService.check(force: true);
      if (!mounted) return;
      if (release == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已是最新版本')),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (_) => UpdateDialog(release: release),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _loadAutostart() async {
    final results = await Future.wait([
      AutostartService.isEnabled(),
      AutostartService.currentMode(),
    ]);
    if (mounted) {
      setState(() {
        _autostartEnabled = results[0] as bool;
        _startupMode = results[1] as StartupMode;
      });
    }
  }

  Future<void> _changeStartupMode(StartupMode mode) async {
    final previous = _startupMode;
    setState(() => _startupMode = mode);
    try {
      await AutostartService.setMode(mode);
      // 已开启自启时，立即用新形态重写注册表命令。
      if (_autostartEnabled == true) {
        await AutostartService.setEnabled(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _startupMode = previous);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _toggleAutostart(bool value) async {
    try {
      await AutostartService.setEnabled(value);
      if (mounted) {
        setState(() => _autostartEnabled = value);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value ? '已开启开机自启动（${_startupMode.label}）' : '已关闭开机自启动'),
        ));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      _loadMobileOptions();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    nameController.dispose();
    repoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Section(
              title: '显示',
              child: ValueListenableBuilder<double>(
                valueListenable: state.fontScaleNotifier,
                builder: (context, scale, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.format_size,
                            size: 20, color: Color(0xFF087F8C)),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '界面字体大小',
                            style: TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${(scale * 100).round()}%',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF087F8C),
                          ),
                        ),
                        if ((scale - 1.0).abs() > 0.001)
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: const Size(0, 30),
                            ),
                            onPressed: () => unawaited(state.setFontScale(1.0)),
                            child: const Text('恢复默认',
                                style: TextStyle(fontSize: 11.5)),
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: '缩小字体',
                          visualDensity: VisualDensity.compact,
                          onPressed: scale <= 0.85
                              ? null
                              : () =>
                                  unawaited(state.setFontScale(scale - 0.05)),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Expanded(
                          child: Slider(
                            value: scale,
                            min: 0.85,
                            max: 1.4,
                            divisions: 11,
                            label: '${(scale * 100).round()}%',
                            onChanged: (value) =>
                                unawaited(state.setFontScale(value)),
                          ),
                        ),
                        IconButton(
                          tooltip: '放大字体',
                          visualDensity: VisualDensity.compact,
                          onPressed: scale >= 1.4
                              ? null
                              : () =>
                                  unawaited(state.setFontScale(scale + 0.05)),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                    const Text(
                      '只调整原传界面，不受系统字体大小影响；设置会保存在本机。',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: Color(0xFF5A6A70)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '本机',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                          labelText: '设备名称', helperText: '对方设备上显示的名字'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () async {
                      await state.renameDevice(nameController.text);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('设备名称已保存')));
                      }
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '接收文件',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FutureBuilder(
                    future: state.gateway.receiveDirectory(),
                    builder: (context, snapshot) => SelectableText(
                      snapshot.hasError
                          ? '无法访问固定保存位置，请先授予文件访问权限'
                          : snapshot.data?.path ?? '正在读取固定保存位置…',
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF37474F)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '信任设备发来的文件会自动保存到这里；同名文件自动加序号，不覆盖原文件。',
                    style: TextStyle(color: Color(0xFF5A6A70), fontSize: 12.5),
                  ),
                  if (state.gateway.isAndroid) ...[
                    const SizedBox(height: 16),
                    FutureBuilder<bool>(
                      future: state.gateway.hasStorageAccess(),
                      builder: (context, snapshot) {
                        final granted = snapshot.data == true;
                        return Row(
                          children: [
                            Icon(
                                granted
                                    ? Icons.check_circle
                                    : Icons.warning_amber,
                                color: granted ? Colors.green : Colors.orange),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(granted
                                    ? '文件访问权限已授予'
                                    : '需要“所有文件访问”权限才能保存任意类型原文件')),
                            if (!granted)
                              TextButton(
                                onPressed: () async {
                                  await state.gateway.requestStorageAccess();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text('授权后请返回应用重新查看状态')));
                                  }
                                },
                                child: const Text('去授权'),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            if (state.gateway.isAndroid) ...[
              const SizedBox(height: 16),
              _Section(
                title: '手机后台',
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _floatingEnabled,
                      onChanged: _toggleFloatingWindow,
                      title: const Text('桌面悬浮球'),
                      subtitle:
                          const Text('在桌面显示可拖动的悬浮球，点击回到原传；首次开启需授权“显示在其他应用上层”'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _bootAutostart,
                      onChanged: _toggleBootAutostart,
                      title: const Text('开机后台启动'),
                      subtitle: const Text('开机后保持接收服务；部分手机需在系统设置中额外允许“自启动”'),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 15, color: Color(0xFF5A6A70)),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '悬浮球由前台传输服务承载；关闭后台服务后悬浮球也会消失。',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.45,
                                  color: Color(0xFF5A6A70)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            _Section(
              title: '接收确认',
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: state.askBeforeReceive,
                    onChanged: (value) => state.setAskBeforeReceive(value),
                    title: const Text('接收前询问'),
                    subtitle: const Text('开启后每个新会话弹窗确认，60 秒不回应自动拒绝；关闭时自动接收'),
                  ),
                ],
              ),
            ),
            if (state.gateway.isAndroid) ...[
              const SizedBox(height: 16),
              _Section(
                title: '自动同步到电脑（聊天消息送达）',
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: state.autoSync.clipboardEnabled,
                      onChanged: (value) async {
                        await state.setSyncClipboard(value);
                        if (context.mounted) setState(() {});
                      },
                      title: const Text('剪贴板文字'),
                      subtitle: const Text('应用在前台时复制的文字自动发到电脑聊天框'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: state.autoSync.imagesEnabled,
                      onChanged: (value) async {
                        await state.setSyncImages(value);
                        if (context.mounted) setState(() {});
                      },
                      title: const Text('下载的图片'),
                      subtitle: const Text('系统下载目录里的新图片自动发到电脑'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: state.autoSync.filesEnabled,
                      onChanged: (value) async {
                        await state.setSyncFiles(value);
                        if (context.mounted) setState(() {});
                      },
                      title: const Text('下载的其他文件'),
                      subtitle: const Text('默认关闭，防止流量意外；同一文件只传一次'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '默认同步目标',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      initialValue: () {
                        final preferred = state.autoSync.preferredTargetId;
                        final ids = {
                          for (final device in state.deviceStore.devices)
                            device.id,
                        };
                        if (preferred != null && ids.contains(preferred)) {
                          return preferred;
                        }
                        return '';
                      }(),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('未指定（仅一台电脑在线时自动同步）'),
                        ),
                        for (final device in state.deviceStore.devices)
                          DropdownMenuItem(
                            value: device.id,
                            child: Text(device.name),
                          ),
                      ],
                      onChanged: (value) async {
                        await state.setSyncTargetDevice(
                          (value == null || value.isEmpty) ? null : value,
                        );
                        if (context.mounted) setState(() {});
                      },
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        helperText: '多台电脑在线时，必须指定目标，避免发错设备',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            _Section(
              title: '信任设备管理',
              child: state.deviceStore.devices.isEmpty
                  ? const Text('暂无配对设备')
                  : Column(
                      children: state.deviceStore.devices
                          .map((device) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading:
                                    const Icon(Icons.verified_user_outlined),
                                title: Text(device.name),
                                subtitle: Text(
                                    '设备密钥已绑定 · ${device.id.substring(0, 8)}'),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除配对',
                                  onPressed: () async {
                                    await state.removeDevice(device.id);
                                    if (context.mounted) setState(() {});
                                  },
                                ),
                              ))
                          .toList(),
                    ),
            ),
            const SizedBox(height: 16),
            if (!state.gateway.isAndroid) ...[
              _Section(
                title: '悬浮窗',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () =>
                                state.setDisplayMode(DisplayMode.bar),
                            icon: const Icon(Icons.dock_outlined, size: 18),
                            label: const Text('切换为悬浮条',
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () =>
                                state.setDisplayMode(DisplayMode.panel),
                            icon: const Icon(
                                Icons.picture_in_picture_alt_outlined,
                                size: 18),
                            label: const Text('展开为小窗',
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '悬浮条常驻桌面右下角，可拖动；点它展开小窗。小窗可拖拽边缘调整大小，尺寸会自动记住。把文件拖到条上或小窗里即可发送。',
                      style:
                          TextStyle(color: Color(0xFF5A6A70), fontSize: 12.5),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _autostartEnabled ?? false,
                      onChanged:
                          _autostartEnabled == null ? null : _toggleAutostart,
                      title: const Text('开机自启动'),
                      subtitle: const Text('登录 Windows 后自动运行，随时接收文件'),
                    ),
                    if (_autostartEnabled == true) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(width: 16),
                          const Icon(Icons.launch_outlined,
                              size: 18, color: Color(0xFF5A6A70)),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              '启动形态',
                              style: TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                          PopupMenuButton<StartupMode>(
                            tooltip: '选择启动形态',
                            initialValue: _startupMode,
                            onSelected: (mode) =>
                                unawaited(_changeStartupMode(mode)),
                            itemBuilder: (context) => [
                              for (final mode in StartupMode.values)
                                PopupMenuItem(
                                  value: mode,
                                  child: Text(mode.label),
                                ),
                            ],
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F5F6),
                                borderRadius: BorderRadius.circular(9),
                                border:
                                    Border.all(color: const Color(0xFFD7E1E3)),
                              ),
                              child: Text(
                                '${_startupMode.label}  ▾',
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF37474F)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(46, 8, 0, 0),
                        child: Text(
                          '静默驻托盘：无窗口，点托盘图标可随时唤出；悬浮条：常驻桌面右下角。',
                          style: TextStyle(
                              color: Color(0xFF5A6A70),
                              fontSize: 12.5,
                              height: 1.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 16),
            _Section(
              title: '应用更新',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本 v$appVersion',
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF54666B))),
                  const SizedBox(height: 10),
                  TextField(
                    controller: repoController,
                    decoration: const InputDecoration(
                      labelText: 'GitHub 仓库',
                      hintText: 'owner/repo',
                      helperText: '填写发布更新包的公开仓库，如 zhangsan/yuanchuan',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: _checkingUpdate ? null : _checkUpdate,
                      icon: _checkingUpdate
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.update, size: 18),
                      label: Text(_checkingUpdate ? '正在检查…' : '检查更新'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _Section(
              title: '传输与隐私',
              child: Text(
                  '文件仅在已配对设备间加密直连，不经过第三方服务器。图片、视频和其他文件均不压缩、不转码，完成后进行 SHA-256 一致性校验。\n\nAndroid 使用前台服务维持后台传输。部分系统的省电策略仍可能结束应用，重新打开后可从未完成记录继续。'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2A2D))),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
