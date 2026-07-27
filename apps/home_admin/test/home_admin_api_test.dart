import 'dart:convert';

import 'package:home_admin/src/api/home_admin_api.dart';
import 'package:home_admin/src/models/family_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('首次初始化家庭使用固定广州时区', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'http://192.168.1.9:8790/api/v1/bootstrap',
      );
      expect(jsonDecode(request.body), {
        'householdName': '我们的家',
        'timezone': 'Asia/Shanghai',
        'username': 'parent',
        'password': 'long-password',
      });
      return http.Response(
        jsonEncode({
          'householdId': 'home-1',
          'roomId': 'room-1',
          'userId': 'user-1',
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = HomeAdminApi(parseFamilyServer('192.168.1.9'), client: client);
    addTearDown(api.close);

    await api.bootstrap(
      householdName: '我们的家',
      username: 'parent',
      password: 'long-password',
    );
  });

  test('家长登录使用 Agent 端口并解析不透明会话', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'http://192.168.1.9:8790/api/v1/auth/login',
      );
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {
        'username': 'parent',
        'password': 'long-password',
      });
      return http.Response(
        jsonEncode({
          'token': 'opaque-parent-token',
          'expiresAt': '2030-01-02T03:04:05Z',
          'userId': 'user-1',
          'householdId': 'home-1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = HomeAdminApi(parseFamilyServer('192.168.1.9'), client: client);
    addTearDown(api.close);

    final session = await api.login(' parent ', 'long-password');

    expect(session.token, 'opaque-parent-token');
    expect(session.userId, 'user-1');
    expect(session.householdId, 'home-1');
    expect(session.server.frameWebSocketUrl, 'ws://192.168.1.9:8780/ws');
  });

  test('家长登录保留服务器错误文案', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'message': '用户名或密码错误'}),
        401,
        headers: {'content-type': 'application/json'},
      ),
    );
    final api = HomeAdminApi(parseFamilyServer('192.168.1.9'), client: client);
    addTearDown(api.close);

    expect(
      () => api.login('parent', 'wrong-password'),
      throwsA(
        isA<HomeAdminApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.message, 'message', '用户名或密码错误'),
      ),
    );
  });

  test('一次性绑定码在 HTTPS 云平台换取家长会话', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://home.example.com/api/v1/auth/enroll',
      );
      expect(jsonDecode(request.body), {
        'code': '7K4M9Q2X',
        'deviceName': 'HomeAdmin Android App',
        'platform': 'android',
      });
      return http.Response(
        jsonEncode({
          'token': 'cloud-token',
          'expiresAt': '2030-01-02T03:04:05Z',
          'userId': 'user-1',
          'householdId': 'home-1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = HomeAdminApi(
      parseFamilyServer('https://home.example.com'),
      client: client,
    );
    addTearDown(api.close);

    final session = await api.enroll(
      ' 7k4m9q2x ',
      deviceName: 'HomeAdmin Android App',
    );

    expect(session.token, 'cloud-token');
    expect(session.server.isCloud, isTrue);
  });

  test('已登录家长可生成只显示一次的绑定码', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/enrollment-codes');
      expect(request.headers['authorization'], 'Bearer cloud-token');
      return http.Response(
        jsonEncode({'code': '7K4M9Q2X', 'expiresAt': '2030-01-02T03:04:05Z'}),
        201,
      );
    });
    final api = HomeAdminApi(
      parseFamilyServer('https://home.example.com'),
      client: client,
    );
    addTearDown(api.close);

    final enrollment = await api.createEnrollmentCode('cloud-token');

    expect(enrollment.code, '7K4M9Q2X');
    expect(enrollment.expiresAt, DateTime.parse('2030-01-02T03:04:05Z'));
  });

  test('读取能力节点并通过统一命令端点控制家庭主服务器', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests += 1;
      expect(request.headers['authorization'], 'Bearer cloud-token');
      if (request.method == 'GET') {
        expect(request.url.path, '/api/v1/nodes');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {
                'id': 'hub-1',
                'name': '家庭主服务器',
                'status': 'online',
                'capabilities': [
                  {
                    'type': 'display.photo',
                    'commands': ['frame.get_state', 'frame.command'],
                  },
                ],
              },
            ]),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(request.url.path, '/api/v1/nodes/hub-1/commands');
      expect(jsonDecode(request.body), {
        'commandName': 'frame.command',
        'arguments': {'action': 'next_photo'},
      });
      return http.Response(
        jsonEncode({
          'success': true,
          'result': {'photo': 'next.jpg', 'photoCount': 10},
          'errorCode': null,
        }),
        200,
      );
    });
    final api = HomeAdminApi(
      parseFamilyServer('https://home.example.com'),
      client: client,
    );
    addTearDown(api.close);

    final nodes = await api.listNodes('cloud-token');
    final result = await api.sendNodeCommand(
      'cloud-token',
      nodes.single.id,
      'frame.command',
      arguments: {'action': 'next_photo'},
    );

    expect(nodes.single.supports('display.photo', 'frame.get_state'), isTrue);
    expect(result.success, isTrue);
    expect(result.result['photo'], 'next.jpg');
    expect(requests, 2);
  });

  test('按 Provider 管理模型与密钥时不会要求或解析明文回读', () async {
    var requests = 0;
    final responseBody = {
      'selection': {'asr': 'volcano', 'tts': 'volcano', 'llm': 'glm'},
      'providers': {
        'asr': [
          {
            'name': 'volcano',
            'label': '火山流式 ASR',
            'configured': true,
            'active': true,
            'streaming': true,
            'state': 'ready',
            'model': 'bigmodel',
            'language': 'zh-CN',
            'fields': [
              {
                'name': 'apiKey',
                'label': 'API Key',
                'type': 'secret',
                'section': 'credential',
                'required': false,
                'allowCustom': false,
                'configured': true,
                'source': 'managed',
                'hint': '••••7890',
              },
              {
                'name': 'model',
                'label': '识别模型',
                'type': 'select',
                'section': 'model',
                'required': true,
                'allowCustom': true,
                'value': 'bigmodel',
                'source': 'environment',
                'options': [
                  {'value': 'bigmodel', 'label': '豆包语音识别大模型'},
                ],
              },
            ],
          },
        ],
        'tts': <Map<String, dynamic>>[],
        'llm': <Map<String, dynamic>>[],
      },
    };
    final client = MockClient((request) async {
      requests += 1;
      expect(request.headers['authorization'], 'Bearer local-token');
      if (request.url.path.endsWith('/asr/volcano/configuration')) {
        expect(jsonDecode(request.body), {
          'values': {'apiKey': 'write-only-secret', 'model': 'bigmodel-v2'},
          'clear': <String>[],
        });
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode(responseBody)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = HomeAdminApi(parseFamilyServer('192.168.1.9'), client: client);
    addTearDown(api.close);

    final status = await api.getProviderStatus('local-token');
    final updated = await api.updateProviderConfiguration(
      'local-token',
      kind: 'asr',
      name: 'volcano',
      values: {'apiKey': 'write-only-secret', 'model': 'bigmodel-v2'},
      clear: const [],
    );

    expect(status.providers['asr']!.single.streaming, isTrue);
    expect(status.providers['asr']!.single.language, 'zh-CN');
    expect(updated.providers['asr']!.single.fields.first.hint, '••••7890');
    expect(requests, 2);
  });
}
