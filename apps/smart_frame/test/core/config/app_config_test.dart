import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/core/config/app_config.dart';

void main() {
  group('AppConfig NAS 字段', () {
    test('默认值', () {
      final c = AppConfig();
      expect(c.city, '广州');
      expect(c.nasEnabled, isFalse);
      expect(c.nasWebdavUrl, 'http://192.168.1.22:5005');
      expect(c.nasWebdavUser, '');
      expect(c.nasWebdavPassword, '');
      expect(c.nasRemoteDir, '');
      expect(c.nasFilterEnabled, isTrue);
      expect(c.nasFilterKeywords, ['截图', 'screenshot', '屏幕快照', '收集']);
      expect(c.musicEnabled, isTrue);
      expect(c.musicMuted, isFalse);
      expect(c.musicVolume, 0.55);
      expect(c.musicQuietStartHour, 22);
      expect(c.musicQuietEndHour, 8);
      expect(c.agentUrl, '');
      expect(c.nodeId, '');
    });

    test('fromJson({}) 缺省时回落默认值', () {
      final c = AppConfig.fromJson({});
      expect(c.city, '广州');
      expect(c.nasEnabled, isFalse);
      expect(c.nasWebdavUrl, 'http://192.168.1.22:5005');
      expect(c.nasWebdavUser, '');
      expect(c.nasWebdavPassword, '');
      expect(c.nasRemoteDir, '');
      expect(c.nasFilterEnabled, isTrue);
      expect(c.nasFilterKeywords, ['截图', 'screenshot', '屏幕快照', '收集']);
      expect(c.musicEnabled, isTrue);
      expect(c.musicVolume, 0.55);
      expect(c.musicOutputEnabled, isTrue);
    });

    test('toJson/fromJson 往返逐字段相等', () {
      final c = AppConfig(
        nasEnabled: true,
        nasWebdavUrl: 'http://10.0.0.9:5006',
        nasWebdavUser: 'frame',
        nasWebdavPassword: 's3cret',
        nasRemoteDir: '/photo/2024',
        nasFilterEnabled: false,
        nasFilterKeywords: ['raw', 'temp'],
        musicEnabled: false,
        musicMuted: true,
        musicVolume: 0.35,
        musicDir: '/music',
        musicOutputEnabled: false,
        musicQuietStartHour: 21,
        musicQuietEndHour: 7,
        agentUrl: 'http://10.0.0.5:8790',
        nodeId: 'node-id',
        roomId: 'room-id',
        deviceKey: 'device-key',
      );
      final restored = AppConfig.fromJson(c.toJson());
      expect(restored.nasEnabled, isTrue);
      expect(restored.nasWebdavUrl, 'http://10.0.0.9:5006');
      expect(restored.nasWebdavUser, 'frame');
      expect(restored.nasWebdavPassword, 's3cret');
      expect(restored.nasRemoteDir, '/photo/2024');
      expect(restored.nasFilterEnabled, isFalse);
      expect(restored.nasFilterKeywords, ['raw', 'temp']);
      expect(restored.musicEnabled, isFalse);
      expect(restored.musicMuted, isTrue);
      expect(restored.musicVolume, 0.35);
      expect(restored.musicDir, '/music');
      expect(restored.musicOutputEnabled, isFalse);
      expect(restored.musicQuietStartHour, 21);
      expect(restored.musicQuietEndHour, 7);
      expect(restored.agentUrl, 'http://10.0.0.5:8790');
      expect(restored.nodeId, 'node-id');
      expect(restored.roomId, 'room-id');
      expect(restored.deviceKey, 'device-key');
    });
  });
}
