import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../config/app_config.dart';
import 'asr_client.dart';
import 'audio_utils.dart';
import 'tts_service.dart';
import 'voice_provider.dart';
import 'wake_word.dart';

enum VoiceState { idle, listening, processing, speaking }

/// 语音状态机：常驻监听麦克风 → 唤醒词 → 录音 → 云端 ASR →
/// 本地意图解析 → 执行 → TTS 播报。唤醒词模型缺失时支持手动触发。
class VoicePipeline extends VoiceProvider {
  VoicePipeline({
    required this.config,
    required this.tts,
    required this.asr,
    required this.onText,
  });

  final AppConfig config;
  final TtsService tts;
  final AsrClient asr;

  /// 把识别出的文字交给指令总线，返回要播报的回复。
  final Future<String> Function(String text) onText;

  VoiceState state = VoiceState.idle;
  String lastHeard = '';
  String lastReply = '';
  bool wakeWordReady = false;
  bool micReady = false;
  @override
  String? statusMessage;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  final List<Uint8List> _capture = [];
  bool _capturing = false;
  WakeWordService? _wake;
  final AudioPlayer _beepPlayer = AudioPlayer();

  // C/S 模式（x86 VoiceServer）：音频从 injectAudio，TTS 推 _externalTts（WS→ARM）
  bool _externalMode = false;
  StreamController<Uint8List>? _externalTts;

  @override
  String get stateText => switch (state) {
        VoiceState.idle => wakeWordReady ? '待唤醒' : '手动模式',
        VoiceState.listening => '聆听中…',
        VoiceState.processing => '识别中…',
        VoiceState.speaking => '播报中…',
      };

  /// C/S 模式：x86 VoiceServer 注入 TTS 输出 sink；音频走 [injectAudio]，
  /// KWS/ASR/TTS/意图仍在 x86 本地跑。
  void startExternal(StreamController<Uint8List> ttsSink) {
    _externalMode = true;
    _externalTts = ttsSink;
  }

  /// 外部喂音频（WS 收 ARM 的 PCM 16k），等同本地 record 的 [_onAudioChunk]。
  void injectAudio(Uint8List chunk) => _onAudioChunk(chunk);

  Future<void> init() async {
    if (_externalMode) {
      // C/S：x86 跑 KWS（音频从 injectAudio），不本地 record
      _wake = WakeWordService(onWake: triggerListen);
      wakeWordReady = _wake!.init(config.wakeWordModelDir);
      notifyListeners();
      return;
    }
    try {
      _recorder = AudioRecorder();
      micReady = await _recorder!.hasPermission();
      if (!micReady) {
        statusMessage = '没有麦克风权限，语音不可用';
        notifyListeners();
        return;
      }

      _wake = WakeWordService(onWake: triggerListen);
      wakeWordReady = _wake!.init(config.wakeWordModelDir);
      if (!wakeWordReady) {
        statusMessage = '未找到唤醒词模型，正在后台下载…';
        notifyListeners();
        unawaited(ensureKwsModel(config.wakeWordModelDir).then((ok) {
          if (ok) {
            wakeWordReady = _wake!.init(config.wakeWordModelDir);
          }
          statusMessage = wakeWordReady ? null : '唤醒词模型不可用，可用空格键或手机按钮触发';
          notifyListeners();
        }));
      }

      final stream = await _recorder!.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _sub = stream.listen(_onAudioChunk);
    } catch (e) {
      statusMessage = '语音初始化失败: $e';
    }
    notifyListeners();
  }

  void _onAudioChunk(Uint8List chunk) {
    if (_capturing) {
      _capture.add(chunk);
      return;
    }
    if (state == VoiceState.idle && wakeWordReady) {
      _wake?.feed(chunk);
    }
  }

  /// 唤醒词命中或手动触发（空格键 / 手机按钮）。
  @override
  Future<void> triggerListen() async {
    if (state != VoiceState.idle) return;
    _setState(VoiceState.listening);
    try {
      await _beepPlayer.play(BytesSource(generateBeepWav()));
    } catch (_) {}
    _wake?.reset();
    _capture.clear();
    _capturing = true;
    await Future.delayed(Duration(seconds: config.listenSeconds));
    _capturing = false;
    _setState(VoiceState.processing);

    if (!asr.isConfigured) {
      await _reply('还没有配置语音识别接口，请在设置里填写 API 地址和密钥。');
      return;
    }
    try {
      final text = await asr.transcribe(pcmToWav(List.of(_capture)));
      lastHeard = text;
      notifyListeners();
      if (text.isEmpty) {
        await _reply('没听清，请再说一次。');
        return;
      }
      await _reply(await onText(text));
    } catch (e) {
      debugPrint('ASR 失败: $e');
      await _reply('语音识别出错了，请检查网络。');
    }
  }

  Future<void> _reply(String text) async {
    lastReply = text;
    _setState(VoiceState.speaking);
    try {
      if (_externalMode && _externalTts != null) {
        // C/S：合成 mp3 推 WS，ARM 播
        final mp3 = await tts.synthesize(text);
        if (mp3.isNotEmpty) _externalTts!.add(mp3);
        await Future.delayed(const Duration(milliseconds: 800));
      } else {
        await tts.speak(text);
        // 等播报完再恢复监听，避免录到自己的声音
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } catch (_) {}
    _wake?.reset();
    _setState(VoiceState.idle);
  }

  void _setState(VoiceState s) {
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder?.dispose();
    _wake?.dispose();
    _beepPlayer.dispose();
    super.dispose();
  }
}
