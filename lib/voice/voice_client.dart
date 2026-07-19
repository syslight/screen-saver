import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';

import 'voice_provider.dart';

/// 展示节点语音瘦客户端：record 采集 16k PCM → WS 推计算节点；收计算节点的
/// state/TTS → 更新 UI + audioplay 播。不跑 KWS/ASR/TTS（全在 x86）。
class VoiceClient extends VoiceProvider {
  VoiceClient(this.computeUrl);

  /// 计算节点根 URL（http），内部转 ws 连 /api/voice
  final String computeUrl;

  @override
  String stateText = '连接中…';
  @override
  String? statusMessage;
  String lastHeard = '';
  String lastReply = '';
  bool micReady = false;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _recSub;
  IOWebSocketChannel? _ws;
  final AudioPlayer _player = AudioPlayer();

  Future<void> init() async {
    _recorder = AudioRecorder();
    try {
      micReady = await _recorder!.hasPermission();
      if (!micReady) {
        statusMessage = '没有麦克风权限，语音不可用';
        notifyListeners();
        return;
      }
    } catch (e) {
      statusMessage = '麦克风初始化失败: $e';
      notifyListeners();
      return;
    }
    _connect();
  }

  void _connect() {
    final wsUrl = '${computeUrl.replaceAll('http://', 'ws://').replaceAll('https://', 'wss://')}/api/voice';
    _ws = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    _ws!.stream.listen(
      (msg) {
        if (msg is Uint8List) {
          // TTS mp3 → 播
          unawaited(_player.play(BytesSource(msg)));
        } else if (msg is String) {
          try {
            final j = jsonDecode(msg) as Map<String, dynamic>;
            if (j['type'] == 'voice_state') {
              stateText = (j['state'] as String?) ?? stateText;
              lastHeard = (j['lastHeard'] as String?) ?? lastHeard;
              lastReply = (j['lastReply'] as String?) ?? lastReply;
              notifyListeners();
            }
          } catch (_) {}
        }
      },
      onDone: () {
        stateText = '已断开';
        notifyListeners();
      },
      onError: (_) {
        stateText = '连接失败';
        notifyListeners();
      },
    );
    _startStream();
  }

  Future<void> _startStream() async {
    try {
      final stream = await _recorder!.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _recSub = stream.listen((chunk) => _ws?.sink.add(chunk));
    } catch (e) {
      statusMessage = '录音启动失败: $e';
      notifyListeners();
    }
  }

  /// 手动触发（空格/手机按钮）→ 通知 x86 triggerListen。
  @override
  Future<void> triggerListen() async {
    _ws?.sink.add(jsonEncode({'type': 'trigger'}));
  }

  @override
  void dispose() {
    _recSub?.cancel();
    _recorder?.dispose();
    _ws?.sink.close();
    _player.dispose();
    super.dispose();
  }
}
