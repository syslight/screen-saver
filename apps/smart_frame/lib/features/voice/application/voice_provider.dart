import 'package:flutter/foundation.dart';

/// 语音状态提供者（UI 抽象）：compute 节点用 [VoicePipeline]（本地 KWS/ASR/TTS），
/// display 节点用 [VoiceClient]（瘦客户端，推流 x86）。UI 只依赖此接口。
abstract class VoiceProvider extends ChangeNotifier {
  String get stateText;
  String? get statusMessage;
  Future<void> triggerListen();
}
