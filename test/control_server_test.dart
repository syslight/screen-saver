import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:smart_frame/config/app_config.dart';
import 'package:smart_frame/server/control_server.dart';
import 'package:smart_frame/server/protocol.dart';
import 'package:smart_frame/services/command_service.dart';
import 'package:smart_frame/services/nas_photo_source.dart';
import 'package:smart_frame/services/photo_index_service.dart';
import 'package:smart_frame/services/photo_service.dart';
import 'package:smart_frame/services/weather_service.dart';
import 'package:smart_frame/voice/tts_service.dart';
import 'package:web_socket_channel/io.dart';

/// 假 NAS 图源（NasPhotoSource 子类，可注入 ControlServer.nas）：
/// 记录 configure 调用、listPhotos 返回固定 refs、ping 恒成功。
/// 不调 super.configure，避免构造真实 webdav 客户端。
class _FakeNasPhotoSource extends NasPhotoSource {
  _FakeNasPhotoSource({this.refs = const []});

  final List<NasPhotoRef> refs;
  int configureCount = 0;
  String? lastPassword;

  @override
  void configure({
    required String url,
    required String user,
    required String password,
    required String remoteDir,
  }) {
    configureCount++;
    lastPassword = password;
  }

  @override
  Future<List<NasPhotoRef>> listPhotos() async => List.of(refs);

  @override
  Future<void> ping() async {}
}

/// 端到端：真实起 HTTP/WS 服务器，验证控制台协议、指令执行、照片上传。
/// TTS 在测试环境无音频插件，speak 内部静默失败，不影响协议验证。
void main() {
  late Directory photoDir;
  late PhotoService photos;
  late WeatherService weather;
  late TtsService tts;
  late CommandService commands;
  late ControlServer server;
  late ConfigService configService;
  late _FakeNasPhotoSource nas;
  late PhotoIndexService photoIndex;

  /// 端口 0 = 系统分配，避免与本机其他服务冲突；setUp 后取实际值
  late int port;

  /// 模拟 Open-Meteo：geocoding 返回北京坐标，forecast 返回固定天气
  /// （http.Response 默认 latin1，中文响应必须走 bytes + utf-8）
  final mockHttp = MockClient((request) async {
    http.Response json(Object data) => http.Response.bytes(
        utf8.encode(jsonEncode(data)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    if (request.url.host.contains('geocoding')) {
      return json({
        'results': [
          {'name': '北京', 'latitude': 39.9, 'longitude': 116.4}
        ]
      });
    }
    return json({
      'current': {
        'temperature_2m': 25.0,
        'relative_humidity_2m': 50,
        'apparent_temperature': 26.0,
        'weather_code': 1,
        'wind_speed_10m': 8.0,
      },
      'daily': {
        'temperature_2m_max': [30.0],
        'temperature_2m_min': [20.0],
        'weather_code': [1],
      },
    });
  });

  /// 建立 WS 连接并返回广播流（单订阅流不能 first 后再 listen）
  (IOWebSocketChannel, Stream<dynamic>) connectWs() {
    final ws = IOWebSocketChannel.connect('ws://localhost:$port/ws');
    return (ws, ws.stream.asBroadcastStream());
  }

  /// 执行 action 期间收集所有服务器消息
  Future<List<Map<String, dynamic>>> collectDuring(
      Stream<dynamic> stream, Future<void> Function() action) async {
    final messages = <Map<String, dynamic>>[];
    final sub = stream.map((m) => jsonDecode(m as String)).listen((m) {
      if (m is Map<String, dynamic>) messages.add(m);
    });
    await action();
    await Future.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    return messages;
  }

  setUp(() async {
    photoDir = await Directory.systemTemp.createTemp('smart_frame_test');
    await File('${photoDir.path}/a.jpg').writeAsBytes([1, 2, 3]);
    await File('${photoDir.path}/b.png').writeAsBytes([4, 5, 6]);

    configService = ConfigService(photoDir.path);
    await configService.load();
    configService.config.photoDir = photoDir.path;
    nas = _FakeNasPhotoSource(refs: [
      NasPhotoRef(path: '/photo/x.jpg', size: 10),
      NasPhotoRef(path: '/photo/y.jpg', size: 20),
    ]);

    photos = PhotoService(photoDir.path);
    await photos.init();
    weather = WeatherService(city: '北京', client: mockHttp);
    tts = TtsService();
    commands = CommandService(
        config: configService.config,
        photos: photos,
        weather: weather,
        tts: tts);
    photoIndex = PhotoIndexService(
        photos, SqliteIndexBackend(p.join(photoDir.path, 'index_test.db')));
    await photoIndex.init(configService.config);
    server = ControlServer(
        port: 0,
        commands: commands,
        photos: photos,
        indexHtml: '<html>console</html>',
        configService: configService,
        nas: nas,
        photoIndex: photoIndex);
    await server.start();
    port = server.boundPort;
  });

  tearDown(() async {
    photoIndex.dispose();
    await server.stop();
    await photoDir.delete(recursive: true);
  });

  test('GET / 返回控制台页面', () async {
    final resp = await http.get(Uri.parse('http://localhost:$port/'));
    expect(resp.statusCode, 200);
    expect(resp.body, '<html>console</html>');
  });

  test('WS 连接即收到状态快照', () async {
    final (ws, stream) = connectWs();
    final first =
        jsonDecode(await stream.first as String) as Map<String, dynamic>;
    expect(first['type'], 'state');
    expect(first['photo'], 'a.jpg');
    expect(first['photoCount'], 2);
    expect(first['nas'], '未启用');
    await ws.sink.close();
  });

  test('指令执行并广播事件和状态', () async {
    final (ws, stream) = connectWs();
    await stream.first; // 跳过初始状态
    final messages = await collectDuring(stream, () async {
      ws.sink.add(jsonEncode({'type': 'command', 'action': 'next_photo'}));
    });
    expect(
        messages
            .any((m) => m['type'] == 'event' && m['message'] == '已切到下一张'),
        isTrue);
    expect(
        messages.any((m) => m['type'] == 'state' && m['photo'] == 'b.png'),
        isTrue);
    expect(photos.currentName, 'b.png');
    await ws.sink.close();
  });

  test('文字指令走意图解析', () async {
    final (ws, stream) = connectWs();
    await stream.first;
    final messages = await collectDuring(stream, () async {
      ws.sink.add(jsonEncode(
          {'type': 'command', 'action': 'text_command', 'text': '今天天气怎么样'}));
    });
    expect(messages.any((m) => m['type'] == 'event'), isTrue);

    await weather.refresh(); // 用 mock HTTP 填充天气数据
    final reply = await commands.executeText('今天天气怎么样');
    expect(reply, contains('北京'));
    expect(reply, contains('25'));
    await ws.sink.close();
  });

  test('设置音量并体现在状态里', () async {
    await commands.executeCommand(decodeCommand(jsonEncode(
        {'type': 'command', 'action': 'set_volume', 'value': 0.3})));
    expect(tts.volume, closeTo(0.3, 0.001));
    expect(commands.currentState()['volume'], closeTo(0.3, 0.001));
  });

  test('multipart 上传照片后相册立即可见', () async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('http://localhost:$port/api/photos'))
      ..files.add(http.MultipartFile.fromBytes('file', [7, 8, 9],
          filename: 'c.jpg'));
    final streamed = await request.send();
    expect(streamed.statusCode, 200);
    final body = jsonDecode(await streamed.stream.bytesToString());
    expect(body['saved'], 1);
    expect(photos.photos.map((item) => item.id).join(','), contains('c.jpg'));
    expect(File('${photoDir.path}/c.jpg').existsSync(), isTrue);
  });

  test('上传非图片被拒绝保存', () async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('http://localhost:$port/api/photos'))
      ..files
          .add(http.MultipartFile.fromBytes('file', [1], filename: 'x.txt'));
    final streamed = await request.send();
    final body = jsonDecode(await streamed.stream.bytesToString());
    expect(body['saved'], 0);
  });

  test('GET /api/config 返回 NAS 配置且不含密码', () async {
    configService.config
      ..nasEnabled = true
      ..nasWebdavUrl = 'http://x:9'
      ..nasWebdavUser = 'u'
      ..nasWebdavPassword = 'secret'
      ..nasRemoteDir = '/photo';
    final resp =
        await http.get(Uri.parse('http://localhost:$port/api/config'));
    expect(resp.statusCode, 200);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['nasEnabled'], true);
    expect(body['nasWebdavUrl'], 'http://x:9');
    expect(body['nasWebdavUser'], 'u');
    expect(body['hasPassword'], true);
    expect(body['nasRemoteDir'], '/photo');
    // 关键：密码绝不返回
    expect(body.containsKey('nasWebdavPassword'), isFalse);
  });

  test('POST /api/config 保存并即时生效，密码空=不改', () async {
    configService.config.nasWebdavPassword = 'oldpass';
    final resp = await http.post(
      Uri.parse('http://localhost:$port/api/config'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'nasEnabled': true,
        'nasWebdavUrl': 'http://192.168.1.22:5005',
        'nasWebdavUser': 'admin',
        'nasWebdavPassword': '',
        'nasRemoteDir': '/photo',
        'nasFilterEnabled': true,
        'nasFilterKeywords': ['截图', 'screenshot'],
      }),
    );
    expect(resp.statusCode, 200);
    expect(jsonDecode(resp.body)['ok'], true);
    final c = configService.config;
    expect(c.nasEnabled, true);
    expect(c.nasWebdavUser, 'admin');
    expect(c.nasRemoteDir, '/photo');
    // 密码空 → 保持原值
    expect(c.nasWebdavPassword, 'oldpass');
    // configure 被调用，传的是未变的原密码
    expect(nas.configureCount, greaterThanOrEqualTo(1));
    expect(nas.lastPassword, 'oldpass');
    // applyNasConfig 生效：fake refs 2 张 → nasStatus 已连接
    await Future.delayed(const Duration(milliseconds: 300));
    expect(photos.nasStatus, contains('已连接 2 张'));
  });

  test('POST /api/config 密码非空则更新', () async {
    await http.post(
      Uri.parse('http://localhost:$port/api/config'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'nasWebdavPassword': 'newpass'}),
    );
    expect(configService.config.nasWebdavPassword, 'newpass');
  });

  test('POST /api/config/test 不可达返回 ok:false', () async {
    final resp = await http.post(
      Uri.parse('http://localhost:$port/api/config/test'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'nasWebdavUrl': 'http://127.0.0.1:1',
        'nasWebdavUser': 'u',
        'nasWebdavPassword': 'p',
        'nasRemoteDir': '/photo',
      }),
    );
    expect(resp.statusCode, 200);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['ok'], false);
    expect(body['message'], contains('连接失败'));
  });

  test('保存 NAS 配置后 nas 状态变化广播到 WS', () async {
    final (ws, stream) = connectWs();
    await stream.first; // 初始快照：未启用
    final messages = await collectDuring(stream, () async {
      await http.post(
        Uri.parse('http://localhost:$port/api/config'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'nasEnabled': true,
          'nasWebdavUrl': 'http://x',
          'nasRemoteDir': '/photo',
        }),
      );
    });
    // applyNasConfig → _refreshNas 成功 → nasStatus 变 → CommandService 监听广播
    expect(
        messages.any((m) =>
            m['type'] == 'state' &&
            ((m['nas'] as String?) ?? '').contains('已连接')),
        isTrue);
    await ws.sink.close();
  });

  test('非法 WS 消息不炸掉连接', () async {
    final (ws, stream) = connectWs();
    await stream.first;
    final messages = await collectDuring(stream, () async {
      ws.sink.add('garbage');
    });
    expect(messages.any((m) => m['type'] == 'event'), isTrue);
    await ws.sink.close();
  });
}
