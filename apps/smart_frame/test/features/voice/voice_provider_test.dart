import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/voice/application/voice_provider.dart';

void main() {
  test('唤醒后的活动状态优先于历史故障提示', () {
    expect(voiceDisplayText('已唤醒，准备聆听…', '旧连接错误'), '已唤醒，准备聆听…');
    expect(voiceDisplayText('聆听中…', '原生唤醒不可用'), '聆听中…');
    expect(voiceDisplayText('识别中…', '旧连接错误'), '识别中…');
    expect(voiceDisplayText('播报中…', '旧连接错误'), '播报中…');
  });

  test('空闲状态仍显示当前诊断信息', () {
    expect(voiceDisplayText('手动对话', '没有麦克风权限'), '没有麦克风权限');
    expect(voiceDisplayText('待唤醒：天猫精灵', null), '待唤醒：天猫精灵');
  });
}
