import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/voice/application/native_wake_word.dart';

void main() {
  test('解析设备原生唤醒事件', () {
    final event = NativeWakeEvent.fromMap({
      'event': 'wake',
      'wakeWord': '天猫精灵',
      'source': 100,
      'adapter': 'firmware_log',
    });

    expect(event.type, NativeWakeEventType.wake);
    expect(event.wakeWord, '天猫精灵');
    expect(event.source, 100);
    expect(event.adapter, 'firmware_log');
  });

  test('解析设备原生唤醒可用状态', () {
    final event = NativeWakeEvent.fromMap({
      'event': 'availability',
      'available': true,
    });

    expect(event.type, NativeWakeEventType.availability);
    expect(event.available, isTrue);
  });
}
