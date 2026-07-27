import 'dart:convert';

import 'package:home_admin/src/frame/frame_control_client.dart';
import 'package:home_admin/src/models/family_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('一个家庭服务器地址派生 Agent、相框 HTTP 和 WebSocket 地址', () {
    final server = parseFamilyServer('192.168.1.9:8790');

    expect(server.agentBaseUrl, 'http://192.168.1.9:8790');
    expect(server.frameBaseUrl, 'http://192.168.1.9:8780');
    expect(server.frameWebSocketUrl, 'ws://192.168.1.9:8780/ws');
  });

  test('家庭服务器地址拒绝路径和非 HTTP 协议', () {
    expect(() => parseFamilyServer('ftp://192.168.1.9'), throwsFormatException);
    expect(
      () => parseFamilyServer('http://192.168.1.9/path'),
      throwsFormatException,
    );
  });

  test('HTTPS 地址使用云平台原始端口且不派生家庭相框端口', () {
    final server = parseFamilyServer('https://home.example.com');

    expect(server.isCloud, isTrue);
    expect(server.agentBaseUrl, 'https://home.example.com');
    expect(server.frameBaseUrl, isNull);
    expect(server.frameWebSocketUrl, isNull);
    expect(
      FamilyServer.fromJson(server.toJson()).agentBaseUrl,
      server.agentBaseUrl,
    );
  });

  test('解析播放端状态并编码控制命令', () {
    final state = FrameState.fromJson({
      'photo': 'family.jpg',
      'photoCount': 42,
      'weather': '广州 晴 28°',
      'voice': '待唤醒',
      'volume': 0.6,
      'musicEnabled': true,
      'musicMuted': false,
      'musicVolume': 0.25,
      'musicTitle': '童年成长 · 原创轻音乐',
      'musicMood': '童年成长',
      'nas': '已连接 100 张',
    });
    final command = jsonDecode(encodeFrameCommand('set_volume', value: 0.35));

    expect(state.photo, 'family.jpg');
    expect(state.photoCount, 42);
    expect(state.volume, 0.6);
    expect(state.musicEnabled, isTrue);
    expect(state.musicVolume, 0.25);
    expect(state.musicMood, '童年成长');
    expect(command, {'type': 'command', 'action': 'set_volume', 'value': 0.35});
  });
}
