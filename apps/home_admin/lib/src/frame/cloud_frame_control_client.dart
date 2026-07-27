import 'dart:async';

import '../api/home_admin_api.dart';
import '../models/family_server.dart';
import 'frame_control_client.dart';

class CloudFrameControlClient extends FrameController {
  CloudFrameControlClient(this.api, this.session);

  final HomeAdminApi api;
  final ParentSession session;

  Timer? _pollTimer;
  Timer? _transitionTimer;
  String? _nodeId;
  bool _closed = false;
  bool _refreshing = false;

  @override
  FrameConnection connection = FrameConnection.disconnected;
  @override
  FrameState state = const FrameState();
  @override
  String? lastEvent;

  @override
  Future<void> connect() async {
    if (_closed || connection == FrameConnection.connecting) return;
    connection = FrameConnection.connecting;
    notifyListeners();
    try {
      final nodes = await api.listNodes(session.token);
      final candidates = nodes.where(
        (node) => node.supports('display.photo', 'frame.get_state'),
      );
      CloudNode? selected;
      for (final node in candidates) {
        if (node.status == 'online') {
          selected = node;
          break;
        }
      }
      if (selected == null) {
        _nodeId = null;
        connection = FrameConnection.disconnected;
        lastEvent = candidates.isEmpty ? '尚未绑定家庭主服务器' : '家庭主服务器当前离线';
        notifyListeners();
        _scheduleReconnect();
        return;
      }
      _nodeId = selected.id;
      connection = FrameConnection.connected;
      lastEvent = '已通过云平台连接 ${selected.name}';
      notifyListeners();
      await _refreshState();
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => unawaited(_refreshState()),
      );
    } on HomeAdminApiException catch (error) {
      _disconnect(error.message);
    } catch (_) {
      _disconnect('云端连接失败，请稍后重试');
    }
  }

  @override
  void send(String action, {String? text, double? value}) {
    if (connection != FrameConnection.connected || _nodeId == null) {
      lastEvent = '家庭主服务器未连接';
      notifyListeners();
      return;
    }
    unawaited(_send(action, text: text, value: value));
  }

  Future<void> _send(String action, {String? text, double? value}) async {
    try {
      final result = await api.sendNodeCommand(
        session.token,
        _nodeId!,
        'frame.command',
        arguments: {'action': action, 'text': ?text, 'value': ?value},
      );
      if (!result.success) {
        lastEvent = _commandError(result.errorCode);
        notifyListeners();
        return;
      }
      _applyState(result.result);
      lastEvent = '指令已执行';
      notifyListeners();
      if (result.result['transitionPending'] == true) {
        _transitionTimer?.cancel();
        _transitionTimer = Timer(
          const Duration(milliseconds: 800),
          () => unawaited(_refreshState()),
        );
      }
    } on HomeAdminApiException catch (error) {
      lastEvent = error.message;
      notifyListeners();
    }
  }

  Future<void> _refreshState() async {
    final nodeId = _nodeId;
    if (_closed || _refreshing || nodeId == null) return;
    _refreshing = true;
    try {
      final result = await api.sendNodeCommand(
        session.token,
        nodeId,
        'frame.get_state',
      );
      if (!result.success) {
        if (result.errorCode == 'node_offline') {
          _disconnect('家庭主服务器当前离线');
        } else {
          lastEvent = _commandError(result.errorCode);
          notifyListeners();
        }
        return;
      }
      _applyState(result.result);
      if (connection != FrameConnection.connected) {
        connection = FrameConnection.connected;
      }
      notifyListeners();
    } on HomeAdminApiException catch (error) {
      _disconnect(error.message);
    } finally {
      _refreshing = false;
    }
  }

  void _applyState(Map<String, dynamic> value) {
    if (value.isNotEmpty) state = FrameState.fromJson(value);
  }

  void _disconnect(String message) {
    if (_closed) return;
    connection = FrameConnection.disconnected;
    lastEvent = message;
    _pollTimer?.cancel();
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _pollTimer?.isActive == true) return;
    _pollTimer = Timer(const Duration(seconds: 5), connect);
  }

  String _commandError(String? code) => switch (code) {
    'node_offline' => '家庭主服务器当前离线',
    'local_service_unavailable' => '家庭主服务器在线，但相册服务未启动',
    'command_timeout' => '指令执行超时，请稍后重试',
    _ => '指令执行失败${code == null ? '' : '（$code）'}',
  };

  @override
  void previewVolume(double value) {
    state = state.copyWith(volume: value.clamp(0, 1));
    notifyListeners();
  }

  @override
  void previewMusicVolume(double value) {
    state = state.copyWith(musicVolume: value.clamp(0, 1));
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _pollTimer?.cancel();
    _transitionTimer?.cancel();
    api.close();
    super.dispose();
  }
}
