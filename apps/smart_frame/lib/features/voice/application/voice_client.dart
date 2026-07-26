import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';

import 'package:smart_frame/features/voice/application/native_wake_word.dart';
import 'package:smart_frame/features/voice/application/voice_provider.dart';

/// 展示节点语音瘦客户端：只采集 PCM，并播放家庭 Agent 返回的 TTS。
class VoiceClient extends VoiceProvider {
  VoiceClient({
    required this.agentUrl,
    required this.nodeId,
    required this.roomId,
    required this.deviceKey,
    this.volume = 0.8,
    this.nativeWakeWord = const NativeWakeWord(),
  });

  final String agentUrl;
  final String nodeId;
  final String roomId;
  final String deviceKey;
  final double volume;
  final NativeWakeWord nativeWakeWord;

  @override
  String stateText = '连接中…';
  @override
  String? statusMessage;
  String lastHeard = '';
  String lastReply = '';
  bool micReady = false;
  bool wakeWordReady = false;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _recSub;
  StreamSubscription<NativeWakeEvent>? _wakeSub;
  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;
  Timer? _followupTimer;
  final AudioPlayer _player = AudioPlayer();
  final Random _random = Random.secure();
  String? _activeTurn;
  int _sequence = 0;
  bool _capturing = false;
  bool _serverIdle = false;
  bool _ttsPlaybackActive = false;
  bool _continueDialog = true;
  bool _closed = false;

  Future<void> init() async {
    _recorder = AudioRecorder();
    try {
      micReady = await _recorder!.hasPermission();
      if (!micReady) {
        statusMessage = '没有麦克风权限，语音不可用';
        notifyListeners();
        return;
      }
      _wakeSub = nativeWakeWord.events.listen(
        _handleNativeWake,
        onError: (_) => _setNativeWakeUnavailable('设备原生唤醒服务不可用'),
      );
      await _connect();
    } catch (e) {
      statusMessage = '麦克风初始化失败: $e';
      notifyListeners();
    }
  }

  void _handleNativeWake(NativeWakeEvent event) {
    if (event.type == NativeWakeEventType.wake) {
      unawaited(_beginTurn());
      return;
    }
    wakeWordReady = event.available;
    statusMessage = event.available
        ? null
        : (event.reason?.isNotEmpty == true
              ? '原生唤醒不可用：${event.reason}'
              : '原生唤醒不可用，可触屏手动对话');
    if (_activeTurn == null) stateText = _idleText;
    notifyListeners();
  }

  void _setNativeWakeUnavailable(String message) {
    wakeWordReady = false;
    statusMessage = message;
    if (_activeTurn == null) stateText = _idleText;
    notifyListeners();
  }

  Future<void> _connect() async {
    if (_closed || _ws != null) return;
    final base = Uri.parse(agentUrl);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/v1/media/voice/ws',
      query: null,
    );
    try {
      final channel = IOWebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      _ws = channel;
      _sequence = 0;
      _sendEnvelope('node.hello', {
        'deviceKey': deviceKey,
        'softwareVersion': '1.0.0',
        'platform': 'flutter-display',
        'mediaProtocolVersion': 1,
      });
      stateText = _idleText;
      if (wakeWordReady) statusMessage = null;
      notifyListeners();
      _wsSub = channel.stream.listen(
        _handleMessage,
        onDone: _disconnect,
        onError: (_) => _disconnect(),
      );
    } catch (e) {
      statusMessage = '语音 Agent 连接失败: $e';
      stateText = '连接失败';
      notifyListeners();
      _disconnect();
    }
  }

  void _handleMessage(dynamic message) {
    if (message is List<int>) {
      unawaited(_playTts(Uint8List.fromList(message)));
      return;
    }
    if (message is! String) return;
    try {
      final envelope = jsonDecode(message) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>? ?? const {};
      if (envelope['type'] != 'voice.turn.state') return;
      final state = payload['state'] as String?;
      stateText = switch (state) {
        'listening' => '聆听中…',
        'processing' => '识别中…',
        'speaking' => '播报中…',
        'error' => '语音服务异常',
        _ => '待唤醒',
      };
      lastHeard = payload['transcript'] as String? ?? lastHeard;
      lastReply = payload['reply'] as String? ?? lastReply;
      _continueDialog = payload['continueDialog'] as bool? ?? _continueDialog;
      if (state == 'processing') {
        unawaited(_stopMicrophone());
      } else if (state == 'idle') {
        unawaited(_stopMicrophone());
        _activeTurn = null;
        _capturing = false;
        _serverIdle = true;
        stateText = _continueDialog ? '等待继续说…' : _idleText;
        unawaited(_maybeStartFollowup());
      } else if (state == 'error') {
        unawaited(_stopMicrophone());
        _activeTurn = null;
        _capturing = false;
        _serverIdle = false;
        _continueDialog = false;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _playTts(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    _ttsPlaybackActive = true;
    try {
      await _player.setVolume(volume.clamp(0.0, 1.0));
      await _player.stop();
      await _player.play(BytesSource(bytes));
      await _player.onPlayerComplete.first.timeout(const Duration(seconds: 90));
    } catch (_) {
      await _player.stop();
    } finally {
      _ttsPlaybackActive = false;
      await _maybeStartFollowup();
    }
  }

  void _handleAudioChunk(Uint8List chunk) {
    final turnId = _activeTurn;
    if (_capturing && turnId != null) {
      _ws?.sink.add(chunk);
    }
  }

  @override
  Future<void> triggerListen() async {
    await _beginTurn();
  }

  Future<void> _beginTurn() async {
    if (_ws == null || _activeTurn != null || _ttsPlaybackActive) return;
    final turnId = _uuid();
    try {
      _followupTimer?.cancel();
      _activeTurn = turnId;
      _capturing = true;
      _serverIdle = false;
      _continueDialog = true;
      stateText = '聆听中…';
      notifyListeners();
      _sendEnvelope('voice.turn.start', {
        'turnId': turnId,
        'encoding': 'pcm_s16le',
        'sampleRate': 16000,
        'channels': 1,
      });
      await _startMicrophone();
    } catch (e) {
      if (_activeTurn == turnId) {
        _sendEnvelope('voice.turn.stop', {'turnId': turnId, 'cancelled': true});
      }
      await _stopMicrophone();
      _activeTurn = null;
      _capturing = false;
      statusMessage = '麦克风录音失败: $e';
      stateText = _idleText;
      notifyListeners();
    }
  }

  Future<void> _startMicrophone() async {
    await _stopMicrophone();
    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _capturing = true;
    _recSub = stream.listen(_handleAudioChunk);
  }

  Future<void> _stopMicrophone() async {
    _capturing = false;
    await _recSub?.cancel();
    _recSub = null;
    if (await _recorder?.isRecording() ?? false) {
      await _recorder?.stop();
    }
  }

  Future<void> _maybeStartFollowup() async {
    if (!_serverIdle ||
        !_continueDialog ||
        _ttsPlaybackActive ||
        _activeTurn != null ||
        _ws == null) {
      if (_serverIdle && !_continueDialog) {
        stateText = _idleText;
        notifyListeners();
      }
      return;
    }
    _serverIdle = false;
    _followupTimer?.cancel();
    _followupTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_beginTurn()),
    );
  }

  String get _idleText => wakeWordReady ? '待唤醒：天猫精灵' : '手动对话';

  void _sendEnvelope(String type, Map<String, dynamic> payload) {
    final channel = _ws;
    if (channel == null) return;
    channel.sink.add(
      jsonEncode({
        'protocolVersion': 1,
        'messageId': _uuid(),
        'sequence': ++_sequence,
        'type': type,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
        'nodeId': nodeId,
        'roomId': roomId,
        'sessionId': null,
        'payload': payload,
      }),
    );
  }

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _disconnect() {
    if (_closed) return;
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    _activeTurn = null;
    _capturing = false;
    _serverIdle = false;
    _continueDialog = false;
    stateText = '已断开';
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connect);
  }

  @override
  void dispose() {
    _closed = true;
    _followupTimer?.cancel();
    _reconnectTimer?.cancel();
    _wakeSub?.cancel();
    _recSub?.cancel();
    _recorder?.dispose();
    _wsSub?.cancel();
    _ws?.sink.close();
    _player.dispose();
    super.dispose();
  }
}
