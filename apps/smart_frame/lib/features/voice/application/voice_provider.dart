import 'package:flutter/foundation.dart';

/// 语音状态提供者。智能屏实现只负责采集和播放；语音计算在 Home Agent。
abstract class VoiceProvider extends ChangeNotifier {
  String get stateText;
  String? get statusMessage;
  Future<void> triggerListen();
}

class UnavailableVoiceProvider extends VoiceProvider {
  UnavailableVoiceProvider(this.statusMessage);

  @override
  final String statusMessage;

  @override
  String get stateText => '语音未配置';

  @override
  Future<void> triggerListen() async {}
}
