import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:smart_frame/features/music/application/music_service.dart';

/// display 节点连接 compute `/ws`：接收家长音乐设置，并把屏幕本地操作回传。
class DisplayControlClient {
  DisplayControlClient({required this.computeUrl, required this.music});

  final String computeUrl;
  final MusicService music;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _closed = false;

  Future<void> connect() async {
    if (_closed || _channel != null) return;
    try {
      final base = Uri.parse(computeUrl);
      final uri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/ws',
        query: null,
      );
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onDone: _disconnect,
        onError: (_) => _disconnect(),
      );
    } catch (error) {
      debugPrint('展示端控制通道连接失败: $error');
      _disconnect();
    }
  }

  void send(String action, double? value) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(
      jsonEncode({'type': 'command', 'action': action, 'value': ?value}),
    );
  }

  void _handleMessage(dynamic message) {
    if (message is! String) return;
    try {
      final state = jsonDecode(message) as Map<String, dynamic>;
      if (state['type'] == 'state') unawaited(music.applyRemoteState(state));
    } catch (_) {}
  }

  void _disconnect() {
    if (_closed) return;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), connect);
  }

  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
