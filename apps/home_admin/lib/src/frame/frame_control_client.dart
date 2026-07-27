import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum FrameConnection { connecting, connected, disconnected }

abstract class FrameController extends ChangeNotifier {
  FrameConnection get connection;
  FrameState get state;
  String? get lastEvent;

  Future<void> connect();
  void send(String action, {String? text, double? value});
  void previewVolume(double value);
  void previewMusicVolume(double value);
}

class FrameState {
  const FrameState({
    this.photo = '—',
    this.photoCount = 0,
    this.weather = '—',
    this.voice = '—',
    this.volume = 0.8,
    this.musicEnabled = false,
    this.musicMuted = true,
    this.musicVolume = 0.55,
    this.musicTitle = '—',
    this.musicMood = '—',
    this.musicQuiet = false,
    this.nas = '—',
  });

  final String photo;
  final int photoCount;
  final String weather;
  final String voice;
  final double volume;
  final bool musicEnabled;
  final bool musicMuted;
  final double musicVolume;
  final String musicTitle;
  final String musicMood;
  final bool musicQuiet;
  final String nas;

  FrameState copyWith({double? volume, double? musicVolume}) => FrameState(
    photo: photo,
    photoCount: photoCount,
    weather: weather,
    voice: voice,
    volume: volume ?? this.volume,
    musicEnabled: musicEnabled,
    musicMuted: musicMuted,
    musicVolume: musicVolume ?? this.musicVolume,
    musicTitle: musicTitle,
    musicMood: musicMood,
    musicQuiet: musicQuiet,
    nas: nas,
  );

  factory FrameState.fromJson(Map<String, dynamic> json) => FrameState(
    photo: json['photo'] as String? ?? '—',
    photoCount: json['photoCount'] as int? ?? 0,
    weather: json['weather'] as String? ?? '—',
    voice: json['voice'] as String? ?? '—',
    volume: (json['volume'] as num?)?.toDouble() ?? 0.8,
    musicEnabled: json['musicEnabled'] as bool? ?? false,
    musicMuted: json['musicMuted'] as bool? ?? true,
    musicVolume: (json['musicVolume'] as num?)?.toDouble() ?? 0.55,
    musicTitle: json['musicTitle'] as String? ?? '—',
    musicMood: json['musicMood'] as String? ?? '—',
    musicQuiet: json['musicQuiet'] as bool? ?? false,
    nas: json['nas'] as String? ?? '—',
  );
}

String encodeFrameCommand(String action, {String? text, double? value}) =>
    jsonEncode({
      'type': 'command',
      'action': action,
      'text': ?text,
      'value': ?value,
    });

class FrameControlClient extends FrameController {
  FrameControlClient(this.webSocketUrl);

  final String webSocketUrl;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _closed = false;

  @override
  FrameConnection connection = FrameConnection.disconnected;
  @override
  FrameState state = const FrameState();
  @override
  String? lastEvent;

  @override
  Future<void> connect() async {
    if (_closed || connection != FrameConnection.disconnected) return;
    _reconnectTimer?.cancel();
    connection = FrameConnection.connecting;
    notifyListeners();
    try {
      final channel = WebSocketChannel.connect(Uri.parse(webSocketUrl));
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      connection = FrameConnection.connected;
      notifyListeners();
      _subscription = channel.stream.listen(
        _handleMessage,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['type'] == 'state') {
        state = FrameState.fromJson(json);
      } else if (json['type'] == 'event') {
        lastEvent = json['message'] as String?;
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  void send(String action, {String? text, double? value}) {
    if (connection != FrameConnection.connected) {
      lastEvent = '播放端未连接';
      notifyListeners();
      return;
    }
    _channel!.sink.add(encodeFrameCommand(action, text: text, value: value));
  }

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

  void _handleDisconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    connection = FrameConnection.disconnected;
    notifyListeners();
    if (!_closed) {
      _reconnectTimer = Timer(const Duration(seconds: 2), connect);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
