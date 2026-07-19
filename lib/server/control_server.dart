import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/command_service.dart';
import '../services/photo_service.dart';
import 'protocol.dart';

/// 内置 HTTP/WebSocket 服务器：serve 手机控制台页面、处理指令与照片上传，
/// 状态变化广播给所有已连接的手机。
class ControlServer {
  ControlServer({
    required this.port,
    required this.commands,
    required this.photos,
    required this.indexHtml,
  });

  final int port;
  final CommandService commands;
  final PhotoService photos;

  /// 控制台单页（Flutter asset 内容）
  final String indexHtml;

  HttpServer? _server;
  final Set<WebSocketChannel> _clients = {};

  /// 实际监听端口（传 0 时由系统分配）
  int get boundPort => _server?.port ?? port;

  /// 局域网访问地址，如 http://192.168.1.5:8780
  String? url;

  int get clientCount => _clients.length;

  Future<void> start() async {
    final router = Router()
      ..get('/',
          (Request req) => Response.ok(indexHtml, headers: _htmlHeaders))
      ..get('/ws', webSocketHandler(_onWebSocket))
      ..post('/api/photos', _onUpload);

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, port);
    final ip = await _lanIp();
    url = 'http://${ip ?? 'localhost'}:$boundPort';
    debugPrint('控制台已启动: $url');

    commands.onEvent = (msg) => broadcast(encodeEvent(msg));
    commands.onStateChanged = _broadcastState;
  }

  static const _htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

  void _onWebSocket(WebSocketChannel ws, String? protocol) {
    _clients.add(ws);
    ws.sink.add(encodeState(commands.currentState()));
    ws.stream.listen(
      (data) async {
        try {
          final cmd = decodeCommand(data as String);
          // executeCommand 内部已通过 onEvent/onStateChanged 广播，无需重复
          await commands.executeCommand(cmd);
        } catch (_) {
          try {
            ws.sink.add(encodeEvent('无法理解的指令'));
          } catch (_) {}
        }
      },
      onDone: () => _clients.remove(ws),
      onError: (_) => _clients.remove(ws),
    );
  }

  Future<Response> _onUpload(Request request) async {
    final form = FormDataRequest.of(request);
    if (form == null) {
      return Response.badRequest(body: 'expected multipart/form-data');
    }
    var saved = 0;
    await for (final field in form.formData) {
      final filename = field.filename;
      if (filename == null) continue;
      final ext = p.extension(filename).toLowerCase();
      if (!PhotoService.imageExts.contains(ext)) continue;
      final bytes = await field.part.readBytes();
      if (bytes.isEmpty) continue;
      final target = File(_uniquePath(photos.photoDir, filename));
      await target.writeAsBytes(bytes);
      saved++;
    }
    await photos.rescan();
    return Response.ok(jsonEncode({'saved': saved}),
        headers: {'content-type': 'application/json'});
  }

  /// 文件名清洗 + 重名加时间戳，防止覆盖和路径穿越。
  static String _uniquePath(String dir, String filename) {
    var name = p.basename(filename).replaceAll(RegExp(r'[^\w.\-一-龥]'), '_');
    if (name.isEmpty || name.startsWith('.')) name = 'photo$name';
    if (File(p.join(dir, name)).existsSync()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      name =
          '${p.basenameWithoutExtension(name)}_$stamp${p.extension(name)}';
    }
    return p.join(dir, name);
  }

  void _broadcastState() =>
      broadcast(encodeState(commands.currentState()));

  void broadcast(String message) {
    for (final client in _clients.toList()) {
      try {
        client.sink.add(message);
      } catch (_) {
        _clients.remove(client);
      }
    }
  }

  Future<void> stop() async {
    for (final client in _clients.toList()) {
      await client.sink.close();
    }
    _clients.clear();
    await _server?.close(force: true);
  }

  static Future<String?> _lanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false);
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
