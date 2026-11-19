import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:flutter/foundation.dart';
// Keep the Material API used by this Flutter stable project.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer_models.dart';
import 'auto_sync.dart';
import 'chat_store.dart';
import 'device_store.dart';
import 'discovery_service.dart';
import 'identity_service.dart';
import 'platform_gateway.dart';
import 'relay_service.dart';
import 'secure_channel.dart';
import 'transfer_manager.dart';
import 'tray_service.dart';
import 'update_service.dart';
import 'window_presenter.dart';

enum DisplayMode { full, panel, bar }

/// 应用根导航；接收确认弹窗从任意形态（完整窗/小窗/悬浮条）弹出时使用。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 一条等待用户确认的接收请求。
class ConsentRequest {
  ConsentRequest(this.offer) : id = randomId();

  final String id;
  final IncomingOffer offer;
  final Completer<bool> completer = Completer<bool>();
}

/// 6 位设备码配对时，把对端公钥绑到人工确认上，避免窗口期内陌生人抢先配对。
class PairingConfirmRequest {
  PairingConfirmRequest(this.hello) : id = randomId();

  final String id;
  final HelloMessage hello;
  final Completer<bool> completer = Completer<bool>();

  /// 短指纹，便于用户口头核对。
  String get fingerprint {
    final key = base64Encode(hello.publicKey);
    return key.length <= 12 ? key : '${key.substring(0, 8)}…${key.substring(key.length - 4)}';
  }
}

class PairingOffer {
  const PairingOffer({
    required this.qrPayload,
    required this.deviceCode,
    required this.hosts,
    required this.port,
    this.relay,
  });

  final String qrPayload;
  final String deviceCode;
  final List<String> hosts;
  final int port;

  /// `host:port` 形式的中继地址；null 表示中继不可用，仅限局域网配对。
  final String? relay;
}

class AppState extends ChangeNotifier {
  AppState({bool startInFloatingBar = false, bool startSilent = false})
      : _startInFloatingBar = startInFloatingBar,
        _startSilent = startSilent;

  static const _fontScaleKey = 'local_file_drop.display.font_scale';
  static const _askReceiveKey = 'local_file_drop.receive.ask';

  final IdentityService identityService = IdentityService();
  final PlatformGateway gateway = PlatformGateway();
  final DeviceStore deviceStore = DeviceStore();
  late final TransferManager transferManager;
  late final ChatStore chatStore;
  late final AutoSyncService autoSync;
  RelayService? _relay;
  final bool _startInFloatingBar;

  /// 应用内字体缩放。独立于系统字体，避免系统超大字号把布局挤坏。
  final ValueNotifier<double> fontScaleNotifier = ValueNotifier(1.0);
  double get fontScale => fontScaleNotifier.value;

  /// 接收前询问（Quick Share 精华）：开启后每个新会话弹窗确认，默认关闭。
  bool _askBeforeReceive = false;
  bool get askBeforeReceive => _askBeforeReceive;

  /// 等待用户确认的接收请求（弹窗在覆盖此列表）。
  final List<ConsentRequest> pendingConsents = [];

  /// 等待用户确认的 6 位码配对（绑定对端公钥）。
  final List<PairingConfirmRequest> pendingPairingConfirms = [];

  /// 静默启动：只驻托盘、不显示任何窗口（开机自启用）。
  final bool _startSilent;
  final Map<String, DiscoveredDevice> _discovered = {};
  // 反向配对用：记住广播里见过但尚未配对的设备地址（PairDrop 双向性）。
  final Map<String, DiscoveredDevice> _unpairedSeen = {};
  DiscoveryService? _discovery;
  Timer? _onlineTimer;
  // 配对窗口期内可用的全部令牌：二维码令牌 + 设备码，共用同一有效期。
  final Set<String> _pairingTokens = {};
  DateTime? _pairingExpires;
  DisplayMode _displayMode = DisplayMode.full;
  final Set<String> _copiedReceived = {};
  // 只对本次运行期间收到的内容亮红点，避免历史记录每次启动都提示。
  final DateTime _sessionStartedAt = DateTime.now();
  bool initialized = false;
  String? startupError;

  /// 启动时检查到新版本时回调，由 UI 弹更新提示。
  void Function(ReleaseInfo release)? onUpdateAvailable;

  DisplayMode get displayMode => _displayMode;
  bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  List<DiscoveredDevice> get devices {
    final now = DateTime.now();
    return deviceStore.devices.map((trusted) {
      return _discovered[trusted.id] ??
          DiscoveredDevice(
              device: trusted,
              host: '',
              port: 0,
              lastSeen: now.subtract(const Duration(days: 1)));
    }).toList()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.device.name.compareTo(b.device.name);
      });
  }

  List<DiscoveredDevice> get onlineDevices => devices
      .where((device) => device.online && device.host.isNotEmpty)
      .toList();

  DiscoveredDevice? endpointFor(String id) => _discovered[id];

  /// 悬浮条红点：已接收但尚未确认复制的文件/文字。
  List<TransferRecord> get pendingReceivedRecords => [
        for (final record in transferManager.records)
          if (record.direction == TransferDirection.receiving &&
              record.status == TransferStatus.completed &&
              !_copiedReceived.contains(record.id) &&
              record.updatedAt.isAfter(_sessionStartedAt) &&
              (record.savePath != null ||
                  (record.isTextRecord && record.textContent != null)))
            record,
      ];

  List<String> get pendingReceivedPaths => [
        for (final record in pendingReceivedRecords)
          if (record.savePath != null) record.savePath!,
      ];

  bool isPendingReceived(TransferRecord record) =>
      pendingReceivedRecords.any((item) => item.id == record.id);

  Future<void> init() async {
    try {
      await _loadFontScale();
      final identity = await identityService.load();
      await deviceStore.load();
      transferManager = TransferManager(
        identity: identity,
        gateway: gateway,
        deviceStore: deviceStore,
        endpointFor: endpointFor,
        authorize: _authorize,
        authorizeOffer: _handleIncomingOffer,
        onBackgroundMessage: (message) {
          unawaited(gateway.updateBackgroundService(message));
        },
        relayDial: (peerId) => RelayService.dial(RelayService.dataKey(peerId)),
      );
      await transferManager.start();
      transferManager.addListener(notifyListeners);
      // 聊天层挂在传输引擎上：启动后的新接收记录自动入会话。
      chatStore = ChatStore(transferManager: transferManager);
      await chatStore.load();
      // 手机自动同步（剪贴板/下载目录）：仅 Android 生效。
      autoSync = AutoSyncService(
        chatStore: chatStore,
        gateway: gateway,
        devices: () => devices,
        onlineDevices: () => onlineDevices,
      );
      await autoSync.load();
      autoSync.start();
      addListener(_onAutoSyncTick);
      _relay = RelayService(
        selfId: identity.id,
        onIncomingConnection: (socket) =>
            transferManager.handleIncomingSocket(socket),
      );
      await _relay!.start();
      _discovery =
          DiscoveryService(identity: identity, onDevice: _onDiscovered);
      await _discovery!.start();
      _onlineTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        // 仅刷新在线状态；保留配对时的地址，广播暂时不可用时仍可尝试直连。
        notifyListeners();
      });
      if (gateway.isAndroid) {
        await gateway.requestNotificationPermission();
        await gateway.startBackgroundService();
      }
      if (isDesktop) {
        await WindowPresenter.init();
        await setDisplayMode(
          _startInFloatingBar ? DisplayMode.bar : DisplayMode.full,
          restorePosition: !_startInFloatingBar,
        );
        // 系统托盘：拦截关闭改为隐藏，托盘可恢复/切悬浮条/退出。
        WindowPresenter.onCloseRequested = () => unawaited(hideToTray());
        await WindowPresenter.setPreventClose(true);
        await TrayService.instance.start(
          _onTrayEvent,
          tooltip: '原传',
          iconPath: _trayIconPath(),
        );
        if (_startSilent) {
          // 开机静默启动：只留托盘图标，不显示窗口。
          await WindowPresenter.hideToTray();
        }
      }
      initialized = true;
      // 后台静默检查更新（6 小时节流，失败无感）。
      unawaited(_autoCheckUpdate());
    } catch (error) {
      startupError = '$error';
    }
    notifyListeners();
  }

  void _onAutoSyncTick() {
    // 设备/在线状态变化时补传断连积压（空队列时是廉价 no-op）。
    if (gateway.isAndroid) unawaited(autoSync.flushBacklog());
  }

  Future<void> setSyncClipboard(bool value) async {
    await autoSync.setClipboardEnabled(value);
    notifyListeners();
  }

  Future<void> setSyncImages(bool value) async {
    await autoSync.setImagesEnabled(value);
    notifyListeners();
  }

  Future<void> setSyncFiles(bool value) async {
    await autoSync.setFilesEnabled(value);
    notifyListeners();
  }

  Future<void> setSyncTargetDevice(String? deviceId) async {
    await autoSync.setPreferredTargetId(deviceId);
    notifyListeners();
  }

  bool get desktopPinned => WindowPresenter.pinned;

  Future<void> toggleDesktopPinned() async {
    if (!isDesktop) return;
    await WindowPresenter.setPinned(!WindowPresenter.pinned);
    notifyListeners();
  }

  Future<void> setDisplayMode(DisplayMode mode,
      {bool restorePosition = false}) async {
    if (isDesktop) {
      // 已经是该形态时不重复重建标题栏/尺寸，只把窗口带回前台。
      if (initialized && mode == _displayMode) {
        await WindowPresenter.showAndFocus();
        return;
      }
      await WindowPresenter.applyMode(
        mode,
        // 回到主窗始终恢复完整尺寸；小窗和悬浮条保留用户调整过的尺寸。
        restorePosition: restorePosition || mode == DisplayMode.full,
      );
    }
    _displayMode = mode;
    notifyListeners();
  }

  Future<void> _loadFontScale() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getDouble(_fontScaleKey) ?? 1.0;
    fontScaleNotifier.value = saved.clamp(0.85, 1.4).toDouble();
    _askBeforeReceive = preferences.getBool(_askReceiveKey) ?? false;
  }

  /// 接收前询问开关：开启后每个新会话首个文件弹窗确认。
  Future<void> setAskBeforeReceive(bool value) async {
    _askBeforeReceive = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_askReceiveKey, value);
    notifyListeners();
  }

  /// 接收确认回调（Quick Share 精华）：询问模式下弹窗，60 秒未回应自动拒绝。
  Future<bool> _handleIncomingOffer(IncomingOffer offer) async {
    if (!_askBeforeReceive) return true;
    final request = ConsentRequest(offer);
    pendingConsents.add(request);
    notifyListeners();
    unawaited(gateway
        .updateBackgroundService('待确认：${offer.peerName} 想发来${offer.summary}'));
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      unawaited(_presentConsentDialog(request, navigator));
    }
    bool granted;
    try {
      granted = await request.completer.future
          .timeout(const Duration(seconds: 60), onTimeout: () => false);
    } finally {
      pendingConsents.remove(request);
      notifyListeners();
    }
    unawaited(gateway.updateBackgroundService('等待传输'));
    return granted;
  }

  Future<void> _presentConsentDialog(
    ConsentRequest request,
    NavigatorState navigator,
  ) async {
    final granted = await showDialog<bool>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('接收请求'),
        content: Text(
            '${request.offer.peerName} 想发来${request.offer.summary}，是否接收？\n\n'
            '60 秒内不回应将自动拒绝。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    if (granted != null && !request.completer.isCompleted) {
      request.completer.complete(granted);
    }
  }

  /// 弹窗/横幅对确认请求的答复入口。
  void answerConsent(String id, bool granted) {
    for (final request in pendingConsents) {
      if (request.id == id && !request.completer.isCompleted) {
        request.completer.complete(granted);
      }
    }
    notifyListeners();
  }

  /// 调整原传界面字体大小，立即生效并记住。
  Future<void> setFontScale(double value) async {
    final clamped = value.clamp(0.85, 1.4).toDouble();
    fontScaleNotifier.value = clamped;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_fontScaleKey, clamped);
  }

  Future<void> _autoCheckUpdate() async {
    try {
      final release = await UpdateService.check();
      if (release == null || onUpdateAvailable == null) return;
      if (await UpdateService.isSkipped(release.version)) return;
      onUpdateAvailable!(release);
    } catch (_) {
      // 更新检查失败不影响正常使用。
    }
  }

  /// 托盘图标路径：优先用安装目录旁的 ico（打包时随 EXE 一起放），
  /// 开发运行时回退到项目 assets 目录。
  String? _trayIconPath() {
    if (!Platform.isWindows) return null;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir${Platform.pathSeparator}tray_icon.ico',
      '${Directory.current.path}${Platform.pathSeparator}assets${Platform.pathSeparator}tray_icon.ico',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 托盘事件：显示主界面 / 悬浮条 / 退出。
  void _onTrayEvent(String event) {
    switch (event) {
      case 'open':
        unawaited(showFromTray(DisplayMode.full));
        break;
      case 'bar':
        unawaited(showFromTray(DisplayMode.bar));
        break;
      case 'exit':
        unawaited(exitApp());
        break;
    }
  }

  /// 点窗口 X：隐藏到托盘，服务继续运行。
  Future<void> hideToTray() async {
    if (!isDesktop) return;
    await WindowPresenter.hideToTray();
  }

  /// 从托盘恢复窗口并显示。
  Future<void> showFromTray([DisplayMode mode = DisplayMode.full]) async {
    if (!isDesktop) return;
    if (mode == _displayMode) {
      await WindowPresenter.showAndFocus();
    } else {
      await setDisplayMode(mode, restorePosition: mode == DisplayMode.full);
    }
    notifyListeners();
  }

  /// 真正退出：托盘与窗口销毁各留 1 秒保底超时，随后硬退出进程。
  /// exit(0) 由操作系统回收全部监听端口与 UDP 套接字；此前任何一步
  /// 卡住（插件无响应、窗口销毁挂起）都不允许挡住退出。
  Future<void> exitApp() async {
    try {
      if (isDesktop) {
        unawaited(TrayService.instance.stop());
        await WindowPresenter.forceClose()
            .timeout(const Duration(seconds: 1), onTimeout: () {});
      }
      dispose();
    } catch (_) {
      // 退出链路上的任何异常都不能阻止 exit(0)。
    }
    exit(0);
  }

  Future<bool> copyPendingReceivedToClipboard() async {
    final records = pendingReceivedRecords;
    if (records.isEmpty) return false;
    final files = [
      for (final record in records)
        if (record.savePath != null) record.savePath!,
    ];
    if (files.isNotEmpty) {
      await WindowPresenter.copyFilesToClipboard(files);
    } else if (records.length == 1 && records.single.textContent != null) {
      await Clipboard.setData(ClipboardData(text: records.single.textContent!));
    } else {
      final text = [
        for (final record in records)
          if (record.textContent != null) record.textContent!,
      ].join('\n\n');
      await Clipboard.setData(ClipboardData(text: text));
    }
    _copiedReceived.addAll(records.map((record) => record.id));
    notifyListeners();
    return true;
  }

  /// 用户点击“确认接收”：文件复制为可在资源管理器粘贴的文件，
  /// 文字写入系统剪贴板；随后清除该条目的红点。
  Future<bool> confirmReceived(TransferRecord record) async {
    if (record.direction != TransferDirection.receiving ||
        record.status != TransferStatus.completed) {
      return false;
    }
    if (record.isTextRecord) {
      final text = record.textContent;
      if (text == null) {
        throw StateError('这条文字来自上次运行，正文未保留，请让对端重新发送');
      }
      await Clipboard.setData(ClipboardData(text: text));
    } else if (record.savePath != null) {
      await WindowPresenter.copyFilesToClipboard([record.savePath!]);
    } else {
      return false;
    }
    _copiedReceived.add(record.id);
    notifyListeners();
    return true;
  }

  void _onDiscovered(DiscoveredDevice discovered) {
    final trusted = deviceStore.byId(discovered.device.id);
    if (trusted == null || trusted.publicKey != discovered.device.publicKey) {
      // 反向配对用：记住广播里见过但尚未配对的设备地址。
      if (trusted == null &&
          discovered.host.isNotEmpty &&
          discovered.port > 0) {
        _unpairedSeen[discovered.device.id] = discovered;
      }
      return;
    }
    final platform = discovered.device.platform != 'unknown'
        ? discovered.device.platform
        : trusted.platform;
    final mergedDevice = discovered.device.copyWith(platform: platform);
    _discovered[discovered.device.id] = DiscoveredDevice(
      device: mergedDevice,
      host: discovered.host,
      port: discovered.port,
      lastSeen: discovered.lastSeen,
    );
    if (trusted.name != mergedDevice.name ||
        trusted.platform != mergedDevice.platform) {
      unawaited(deviceStore.addOrUpdate(mergedDevice));
    }
    notifyListeners();
  }

  Future<bool> _authorize(HelloMessage hello) async {
    final trusted = deviceStore.byId(hello.deviceId);
    if (trusted != null) {
      if (trusted.publicKey != base64Encode(hello.publicKey)) return false;
      await deviceStore.addOrUpdate(TrustedDevice(
        id: hello.deviceId,
        name: hello.name,
        publicKey: trusted.publicKey,
        platform: trusted.platform == 'unknown'
            ? (isDesktop ? 'mobile' : 'windows')
            : trusted.platform,
      ));
      return true;
    }
    final expires = _pairingExpires;
    if (_pairingTokens.isEmpty ||
        expires == null ||
        DateTime.now().isAfter(expires)) {
      return false;
    }
    final token = hello.pairingToken;
    if (token == null || !_pairingTokens.contains(token)) return false;

    // 6 位设备码：必须人工确认，把「这个公钥」绑进配对结果；
    // 确认后该码作废，陌生人无法在同一窗口再抢先完成配对。
    final isDeviceCode = RegExp(r'^\d{6}$').hasMatch(token);
    if (isDeviceCode) {
      final confirmed = await _confirmDeviceCodePairing(hello);
      if (!confirmed) return false;
      _pairingTokens.remove(token);
    }

    await deviceStore.addOrUpdate(TrustedDevice(
      id: hello.deviceId,
      name: hello.name,
      publicKey: base64Encode(hello.publicKey),
      platform: isDesktop ? 'mobile' : 'windows',
    ));
    notifyListeners();
    return true;
  }

  Future<bool> _confirmDeviceCodePairing(HelloMessage hello) async {
    final request = PairingConfirmRequest(hello);
    pendingPairingConfirms.add(request);
    notifyListeners();
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      unawaited(_presentPairingConfirmDialog(request, navigator));
    }
    try {
      return await request.completer.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => false,
      );
    } finally {
      pendingPairingConfirms.remove(request);
      notifyListeners();
    }
  }

  Future<void> _presentPairingConfirmDialog(
    PairingConfirmRequest request,
    NavigatorState navigator,
  ) async {
    final granted = await showDialog<bool>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('确认配对'),
        content: Text(
          '设备「${request.hello.name}」正在用设备码请求配对。\n'
          '密钥指纹：${request.fingerprint}\n\n'
          '请确认这是你的设备后再允许；陌生人即使猜中设备码也无法在未确认时完成配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('允许并绑定'),
          ),
        ],
      ),
    );
    if (!request.completer.isCompleted) {
      request.completer.complete(granted == true);
    }
  }

  void resolvePairingConfirm(String id, bool allowed) {
    for (final request in pendingPairingConfirms) {
      if (request.id == id && !request.completer.isCompleted) {
        request.completer.complete(allowed);
        break;
      }
    }
  }

  /// 电脑端经中继配对房间的握手服务端。
  ///
  /// 手机经中继拨入后，在此 socket 上跑与直连相同的 SecureChannel.accept：
  /// 校验 hello 中的配对码、回 helloAck、登记对端。配对完成后关闭连接，
  /// 后续文件传输由 RelayService 的常驻 `D:<id>` 监听处理。
  Future<void> _servePairingHandshake(Socket socket) async {
    SecureChannel? channel;
    try {
      channel = await SecureChannel.accept(
        socket,
        identity: identityService.identity,
        authorize: _authorize,
        // 玩家从看到配对码到输入需要时间；5 分钟内等到对端即可。
        handshakeTimeout: const Duration(minutes: 5),
      );
      // 登记经中继配对的设备；host 留空，避免记录不可达的直连地址。
      await deviceStore.addOrUpdate(TrustedDevice(
        id: channel.peerId,
        name: channel.peerName,
        publicKey: base64Encode(channel.peerPublicKey),
        platform: isDesktop ? 'mobile' : 'windows',
      ));
      notifyListeners();
    } catch (_) {
      // 对端超时未拨入、配对码失效或握手失败，属正常，静默释放房间。
    } finally {
      try {
        await channel?.close();
      } catch (_) {}
      if (channel == null) {
        try {
          await socket.close();
        } catch (_) {}
      }
    }
  }

  /// 生成一次配对会话：二维码载荷（含全部候选地址与中继）+ 6 位设备码。
  /// 两种方式在 5 分钟内都有效，任一成功即完成配对。
  /// 二维码 v3：跨网时手机先试直连，失败自动经中继完成配对与传输。
  Future<PairingOffer> beginPairing() async {
    final identity = identityService.identity;
    _pairingTokens
      ..clear()
      ..add(randomId(32))
      ..add(_generateDeviceCode());
    _pairingExpires = DateTime.now().add(const Duration(minutes: 5));
    final hosts = await localIPv4Addresses();
    String? relayAddress;
    if (_relay != null) {
      _relay!.releaseHeldRooms();
      final qrToken = _pairingTokens.first;
      final deviceCode = _pairingTokens.last;
      final relayUp = await RelayService.reachable();
      if (relayUp) {
        try {
          // 二维码令牌与设备码各占一个房间，两种配对方式都支持跨网。
          // 关键：必须传 onPaired 在桥接 socket 上完成握手应答，
          // 否则手机经中继拨入后发的 hello 无人回复，会永远卡在“正在配对”。
          unawaited(
            _relay!.holdPairingRoom(
              RelayService.pairingKey(qrToken),
              onPaired: _servePairingHandshake,
            ),
          );
          unawaited(
            _relay!.holdPairingRoom(
              RelayService.pairingKey(deviceCode),
              onPaired: _servePairingHandshake,
            ),
          );
          relayAddress =
              '${RelayService.defaultRelayHost}:${RelayService.defaultRelayPort}';
        } catch (_) {
          relayAddress = null;
        }
      }
    }
    final payload = jsonEncode({
      'app': 'LocalFileDrop',
      'version': 3,
      'id': identity.id,
      'name': identity.name,
      'publicKey': identity.publicKeyBase64,
      'platform': Platform.operatingSystem,
      'hosts': hosts,
      // 旧版本客户端只读 host 字段，保留兼容。
      'host': hosts.first,
      'port': transferManager.serverPort,
      if (relayAddress != null) 'relay': relayAddress,
      'token': _pairingTokens.first,
      'expires': _pairingExpires!.toIso8601String(),
    });
    return PairingOffer(
      qrPayload: payload,
      deviceCode: _pairingTokens.last,
      hosts: hosts,
      port: transferManager.serverPort ?? 0,
      relay: relayAddress,
    );
  }

  String _generateDeviceCode() {
    return (Random.secure().nextInt(900000) + 100000).toString();
  }

  Future<void> pairFromQr(String raw) => _pairFromPayload(raw);

  /// 反向配对（PairDrop 精华）：对端（手机）显示 6 位设备码，本机凭码配对。
  ///
  /// 局域网：优先直连广播里见过的未配对设备地址；跨网：经中继
  /// `P:<码>` 配对房间拨入（对端已用同一码 hold 房间）。任一成功即配对。
  Future<void> pairByCodeOnly(String code) async {
    final trimmed = code.trim();
    if (trimmed.length != 6 || int.tryParse(trimmed) == null) {
      throw const FormatException('设备码是 6 位数字');
    }
    final now = DateTime.now();
    _unpairedSeen.removeWhere(
        (_, device) => now.difference(device.lastSeen).inMinutes > 10);
    final hosts = [
      for (final device in _unpairedSeen.values)
        if (device.port > 0 && device.host.isNotEmpty) device.host,
    ];
    await _establishPairing(
      hosts: hosts,
      port: hosts.isEmpty ? 0 : _unpairedSeen.values.first.port,
      token: trimmed,
      expectedDeviceId: null,
      expectedPublicKey: null,
      relay: RelayService.defaultRelayAddress,
    );
  }

  Future<void> pairWithCode(
    String host,
    int port,
    String code, {
    String? relay,
  }) async {
    final trimmedHost = host.trim();
    final trimmedRelay = (relay ?? '').trim();
    final trimmedCode = code.trim();
    if (port <= 0 || port > 65535) {
      throw const FormatException('端口无效（应为 1-65535）');
    }
    // 跨网配对时没有可达的局域网 IP：只要保留中继地址即可，允许 IP 留空。
    // 与界面提示“不在同一网络时保留下方中继地址即可走流量配对”保持一致。
    if (trimmedHost.isEmpty && trimmedRelay.isEmpty) {
      throw const FormatException('请填写电脑的局域网 IP，或保留中继地址用于跨网配对');
    }
    if (trimmedCode.length != 6 || int.tryParse(trimmedCode) == null) {
      throw const FormatException('设备码是 6 位数字');
    }
    await _establishPairing(
      hosts: trimmedHost.isEmpty ? const <String>[] : [trimmedHost],
      port: port,
      token: trimmedCode,
      expectedDeviceId: null,
      expectedPublicKey: null,
      relay: trimmedRelay.isEmpty ? null : trimmedRelay,
    );
  }

  Future<void> _pairFromPayload(String raw) async {
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    if (payload['app'] != 'LocalFileDrop') {
      throw const FormatException('这不是“原传”的配对二维码');
    }
    if (payload['version'] != 1 &&
        payload['version'] != 2 &&
        payload['version'] != 3) {
      throw const FormatException('二维码版本过旧，请在电脑上重新生成');
    }
    final expires = DateTime.parse(payload['expires'] as String);
    if (DateTime.now().isAfter(expires)) {
      throw const FormatException('二维码已过期，请在电脑上重新生成');
    }
    final device = TrustedDevice(
      id: payload['id'] as String,
      name: payload['name'] as String,
      publicKey: payload['publicKey'] as String,
      platform: payload['platform'] as String? ?? 'windows',
    );
    if (device.id == identityService.identity.id) {
      throw const FormatException('不能与本机配对');
    }
    final port = (payload['port'] as num).toInt();
    final hosts = <String>[
      if (payload['hosts'] is List)
        for (final value in (payload['hosts'] as List))
          if (value is String) value,
      if (payload['host'] is String) payload['host'] as String,
    ];
    if (hosts.isEmpty) {
      throw const FormatException('二维码中没有可用地址');
    }
    await _establishPairing(
      hosts: hosts,
      port: port,
      token: payload['token'] as String,
      expectedDeviceId: device.id,
      expectedPublicKey: base64Decode(device.publicKey),
      relay: payload['relay'] is String ? payload['relay'] as String : null,
    );
  }

  /// 直连候选与中继并行竞速：谁先握手成功用谁，避免过期局域网地址卡住。
  Future<void> _establishPairing({
    required List<String> hosts,
    required int port,
    required String token,
    required String? expectedDeviceId,
    required List<int>? expectedPublicKey,
    String? relay,
  }) async {
    final uniqueHosts = hosts.toSet().toList();
    final directTimeout = relay == null ? 5 : 2;
    final attempts = <Future<bool>>[
      for (final host in uniqueHosts)
        _attemptHost(
          host,
          port,
          token,
          expectedDeviceId,
          expectedPublicKey,
          directTimeout,
        ),
      if (relay != null)
        _attemptRelay(
          relay,
          token,
          expectedDeviceId,
          expectedPublicKey,
        ),
    ];
    if (attempts.isEmpty) {
      throw const SocketException(
        '没有可用的配对地址。请填写局域网 IP 或保留中继地址。',
      );
    }
    final completer = Completer<bool>();
    var remaining = attempts.length;
    for (final attempt in attempts) {
      unawaited(attempt.then((ok) {
        if (ok && !completer.isCompleted) {
          completer.complete(true);
        } else {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(false);
          }
        }
      }));
    }
    final ok = await completer.future.timeout(
      Duration(seconds: relay == null ? 8 : 6),
      onTimeout: () => false,
    );
    if (ok) return;
    throw const SocketException(
      '无法连接到电脑。请确认两端在同一个局域网（同一 Wi-Fi 或同一热点），'
      '或电脑端已连接中继且配对码仍在有效期内。',
    );
  }

  /// 经中继配对：与电脑在配对房间桥接后走同一套安全握手。
  Future<bool> _attemptRelay(
    String relay,
    String token,
    String? expectedDeviceId,
    List<int>? expectedPublicKey,
  ) async {
    Socket? socket;
    SecureChannel? channel;
    try {
      final parts = relay.split(':');
      final host = parts.first;
      final port = parts.length > 1
          ? int.tryParse(parts[1]) ?? RelayService.defaultRelayPort
          : RelayService.defaultRelayPort;
      socket = await RelayService.dial(
        RelayService.pairingKey(token),
        host: host,
        port: port,
      );
      channel = await SecureChannel.connect(
        socket,
        identity: identityService.identity,
        pairingToken: token,
        expectedDeviceId: expectedDeviceId,
        expectedPublicKey: expectedPublicKey,
      );
      // 经中继配对的设备没有直连端点，host 留空避免记录不可达地址。
      await _registerPeer(channel, '', port);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await channel?.close();
      } catch (_) {}
      if (channel == null) {
        try {
          await socket?.close();
        } catch (_) {}
      }
    }
  }

  Future<bool> _attemptHost(
    String host,
    int port,
    String token,
    String? expectedDeviceId,
    List<int>? expectedPublicKey,
    int timeoutSeconds,
  ) async {
    Socket? socket;
    SecureChannel? channel;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: Duration(seconds: timeoutSeconds),
      );
      channel = await SecureChannel.connect(
        socket,
        identity: identityService.identity,
        pairingToken: token,
        expectedDeviceId: expectedDeviceId,
        expectedPublicKey: expectedPublicKey,
      );
      await _registerPeer(channel, host, port);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await channel?.close();
      } catch (_) {}
      if (channel == null) {
        try {
          await socket?.close();
        } catch (_) {}
      }
    }
  }

  /// 握手成功后钉住对端身份并记录地址。
  Future<void> _registerPeer(
    SecureChannel channel,
    String host,
    int port,
  ) async {
    final trusted = TrustedDevice(
      id: channel.peerId,
      name: channel.peerName,
      publicKey: base64Encode(channel.peerPublicKey),
      platform: deviceStore.byId(channel.peerId)?.platform ??
          (isDesktop ? 'mobile' : 'windows'),
    );
    await deviceStore.addOrUpdate(trusted);
    if (host.isNotEmpty) {
      _discovered[channel.peerId] = DiscoveredDevice(
        device: trusted,
        host: host,
        port: port,
        lastSeen: DateTime.now(),
      );
    }
    notifyListeners();
  }

  Future<void> sendFiles(DiscoveredDevice device) async {
    final items = await gateway.pickFiles();
    if (items.isEmpty) return;
    unawaited(transferManager.sendItems(items, device));
  }

  Future<void> sendImages(DiscoveredDevice device) async {
    final items = await gateway.pickImages();
    if (items.isEmpty) return;
    unawaited(transferManager.sendItems(items, device));
  }

  Future<void> sendFolder(DiscoveredDevice device) async {
    final items = await gateway.pickFolder();
    if (items.isEmpty) return;
    unawaited(transferManager.sendItems(items, device));
  }

  /// 发送任意长度文字，走与文件相同的加密分块通道。
  Future<void> sendText(DiscoveredDevice device, String text) async {
    if (text.isEmpty) return;
    await transferManager.sendText(text, device);
  }

  /// 悬浮条/小窗拖入文件后直接发送。
  Future<void> sendDroppedPaths(
      DiscoveredDevice device, List<String> paths) async {
    final items = await gateway.itemsFromPaths(paths);
    if (items.isEmpty) return;
    unawaited(transferManager.sendItems(items, device));
  }

  Future<void> removeDevice(String id) async {
    await deviceStore.remove(id);
    _discovered.remove(id);
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    await identityService.rename(name);
    await _discovery?.announce();
    notifyListeners();
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    if (isDesktop) {
      WindowPresenter.onCloseRequested = null;
      TrayService.instance.stop();
    }
    chatStore.dispose();
    autoSync.stop();
    unawaited(_discovery?.close());
    unawaited(_relay?.stop());
    if (gateway.isAndroid) unawaited(gateway.stopBackgroundService());
    if (initialized) unawaited(transferManager.close());
    fontScaleNotifier.dispose();
    super.dispose();
  }
}
