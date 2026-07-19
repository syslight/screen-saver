import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_frame/config/app_config.dart';
import 'package:smart_frame/server/control_server.dart';
import 'package:smart_frame/server/protocol.dart';
import 'package:smart_frame/services/command_service.dart';
import 'package:smart_frame/services/photo_service.dart';
import 'package:smart_frame/services/weather_service.dart';
import 'package:smart_frame/voice/tts_service.dart';
import 'package:web_socket_channel/io.dart';

/// 端到端：真实起 HTTP/WS 服务器，验证控制台协议、指令执行、照片上传。
/// TTS 在测试环境无音频插件，speak 内部静默失败，不影响协议验证。
void main() {
  late Directory photoDir;
  late PhotoService photos;
  late WeatherService weather;
  late TtsService tts;
  late CommandService commands;
  late ControlServer server;

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

    photos = PhotoService(photoDir.path);
    await photos.init();
    weather = WeatherService(city: '北京', client: mockHttp);
    tts = TtsService();
    commands = CommandService(
        config: AppConfig(photoDir: photoDir.path),
        photos: photos,
        weather: weather,
        tts: tts);
    server = ControlServer(
        port: 0,
        commands: commands,
        photos: photos,
        indexHtml: '<html>console</html>');
    await server.start();
    port = server.boundPort;
  });

  tearDown(() async {
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
