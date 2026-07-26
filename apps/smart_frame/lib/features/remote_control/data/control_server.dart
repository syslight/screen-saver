import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image_lib;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:smart_frame/core/config/app_config.dart';
import 'package:smart_frame/features/remote_control/application/command_service.dart';
import 'package:smart_frame/features/photos/data/nas_photo_source.dart';
import 'package:smart_frame/features/photos/application/photo_index_service.dart';
import 'package:smart_frame/features/photos/application/photo_service.dart';
import 'package:smart_frame/features/remote_control/domain/protocol.dart';

/// 内置 HTTP/WebSocket 服务器：serve 手机控制台页面、处理指令与照片上传，
/// 状态变化广播给所有已连接的手机。
class ControlServer {
  ControlServer({
    required this.port,
    required this.commands,
    required this.photos,
    required this.indexHtml,
    required this.configService,
    required this.nas,
    required this.photoIndex,
  });

  final int port;
  final CommandService commands;
  final PhotoService photos;

  /// 控制台单页（Flutter asset 内容）
  final String indexHtml;

  /// 配置读写（web 端 NAS 配置入口用）
  final ConfigService configService;

  /// NAS 图源（compute=NasPhotoSource 连 NAS；display=HttpPhotoSource 拉 HTTP）
  final NasSource nas;

  /// 照片索引/去重服务（保存配置后应用去重开关）
  final PhotoIndexService photoIndex;

  HttpServer? _server;
  final Set<WebSocketChannel> _clients = {};

  /// 实际监听端口（传 0 时由系统分配）
  int get boundPort => _server?.port ?? port;

  /// 局域网访问地址，如 http://192.168.1.5:8780
  String? url;

  int get clientCount => _clients.length;

  Future<void> start() async {
    final router = Router()
      ..get('/', (Request req) => Response.ok(indexHtml, headers: _htmlHeaders))
      ..get('/ws', webSocketHandler(_onWebSocket))
      ..get('/api/config', _onGetConfig)
      ..post('/api/config', _onPutConfig)
      ..post('/api/config/test', _onTestConfig)
      ..get('/api/photos/list', _onPhotosList)
      ..get('/api/photos/file', _onPhotosFile)
      ..get('/api/index/status', _onIndexStatus)
      ..get('/api/index/hidden', _onIndexHidden)
      ..get('/api/index/bytag', _onIndexByTag)
      ..get('/api/index/byperson', _onIndexByPerson)
      ..get('/api/index/persons', _onIndexPersons)
      ..get('/api/index/person-profiles', _onPersonProfiles)
      ..post('/api/index/person-profile', _onSetPersonProfile)
      ..get('/api/index/person-face', _onPersonFace)
      ..get('/api/index/description', _onIndexDescription)
      ..get('/api/search/similar', (r) => _proxySearch(r, 'similar'))
      ..get('/api/search/text', (r) => _proxySearch(r, 'text'))
      ..post('/api/annotate', _onAnnotate)
      ..post('/api/filter', _onFilter)
      ..post('/api/filter/clear', _onFilterClear)
      ..post('/api/photos', _onUpload);

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, port);
    final ip = await _lanIp();
    url = 'http://${ip ?? 'localhost'}:$boundPort';
    debugPrint('控制台已启动: $url');

    commands.onEvent = (msg) => broadcast(encodeEvent(msg));
    commands.onStateChanged = _broadcastState;
  }

  static const _htmlHeaders = {'content-type': 'text/html; charset=utf-8'};
  static const _jsonHeaders = {
    'content-type': 'application/json; charset=utf-8',
  };

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
    return Response.ok(
      jsonEncode({'saved': saved}),
      headers: {'content-type': 'application/json'},
    );
  }

  // ===== C/S 数据端点（供 ARM 展示节点拉照片 + 索引）=====

  /// 照片列表（id = 远程 path，与索引 hidden 对齐）。
  Future<Response> _onPhotosList(Request req) async {
    final list = [
      for (final p in photos.photos)
        {
          'id': p.id,
          'name': p.name,
          'isNas': p.isNas,
          'modifiedAt': p.modifiedAt?.millisecondsSinceEpoch,
        },
    ];
    return Response.ok(
      jsonEncode({'photos': list, 'nas': photos.nasStatus}),
      headers: _jsonHeaders,
    );
  }

  /// 照片字节（`?id=path`）：复用 fileFor（本地直返 / NAS 缓存 / HEIC 转 jpg）。
  Future<Response> _onPhotosFile(Request req) async {
    final id = req.url.queryParameters['id'];
    if (id == null) return Response.badRequest(body: 'missing id');
    PhotoItem? item;
    for (final p in photos.photos) {
      if (p.id == id) {
        item = p;
        break;
      }
    }
    if (item == null) return Response.notFound('photo not found');
    final file = await photos.fileFor(item);
    if (file == null || !file.existsSync()) {
      return Response.notFound('file unavailable');
    }
    final bytes = await file.readAsBytes();
    return Response.ok(bytes, headers: {'content-type': 'image/jpeg'});
  }

  Future<Response> _onIndexStatus(Request req) async {
    return Response.ok(
      jsonEncode({
        'indexStatus': photoIndex.indexStatus,
        ...photoIndex.statusMap,
      }),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _onIndexHidden(Request req) async {
    return Response.ok(
      jsonEncode({'hidden': photoIndex.hiddenIds.toList()}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _onIndexByTag(Request req) async {
    final t = req.url.queryParameters['t'] ?? '';
    final ids = await photoIndex.byTag(t);
    return Response.ok(
      jsonEncode({'ids': ids.toList()}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _onIndexByPerson(Request req) async {
    final p = req.url.queryParameters['p'] ?? '';
    final ids = await photoIndex.byPerson(p);
    return Response.ok(
      jsonEncode({'ids': ids.toList()}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _onIndexPersons(Request req) async {
    final persons = await photoIndex.persons();
    return Response.ok(jsonEncode({'persons': persons}), headers: _jsonHeaders);
  }

  Future<Response> _onPersonProfiles(Request req) async {
    final status = req.url.queryParameters['status'] ?? 'all';
    final confirmed = switch (status) {
      'all' => null,
      'confirmed' => true,
      'unconfirmed' => false,
      _ => false,
    };
    if (!const {'all', 'confirmed', 'unconfirmed'}.contains(status)) {
      return _badRequest('status 必须为 all、confirmed 或 unconfirmed');
    }
    final limit = int.tryParse(req.url.queryParameters['limit'] ?? '12');
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '0');
    if (limit == null ||
        limit < 1 ||
        limit > 50 ||
        offset == null ||
        offset < 0) {
      return _badRequest('limit 必须为 1..50，offset 必须大于等于 0');
    }
    final page = await photoIndex.personProfiles(
      confirmed: confirmed,
      limit: limit,
      offset: offset,
    );
    return Response.ok(jsonEncode(page.toJson()), headers: _jsonHeaders);
  }

  Future<Response> _onSetPersonProfile(Request req) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('请求体不是合法 JSON');
    }
    final subject = (body['subjectName'] as String?)?.trim();
    final rawLabel = body['identityLabel'];
    if (subject == null || subject.isEmpty) {
      return _badRequest('缺少 subjectName');
    }
    if (rawLabel != null && rawLabel is! String) {
      return _badRequest('identityLabel 必须为字符串或 null');
    }
    final label = rawLabel is String ? rawLabel.trim() : null;
    if (label != null && !familyIdentityLabels.contains(label)) {
      return _badRequest('identityLabel 不是允许的家庭关系称谓');
    }
    try {
      await photoIndex.setPersonIdentity(subject, label);
      return Response.ok(
        jsonEncode({
          'ok': true,
          'subjectName': subject,
          'identityLabel': label,
          'confirmed': label != null,
        }),
        headers: _jsonHeaders,
      );
    } on ArgumentError catch (error) {
      return _badRequest(error.message?.toString() ?? '人物聚类不存在');
    } catch (error) {
      return Response.internalServerError(
        body: jsonEncode({'ok': false, 'error': '$error'}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _onPersonFace(Request req) async {
    final faceId = int.tryParse(req.url.queryParameters['id'] ?? '');
    if (faceId == null || faceId < 1) return _badRequest('id 必须为正整数');
    final sample = await photoIndex.backend.faceSample(faceId);
    if (sample == null || sample.bbox.length < 4) {
      return Response.notFound('face sample not found');
    }
    if (req.url.queryParameters['meta'] == '1') {
      return Response.ok(jsonEncode(sample.toJson()), headers: _jsonHeaders);
    }
    final file = await photos.fileForId(sample.photoId);
    if (file == null || !file.existsSync()) {
      return Response.notFound('file unavailable');
    }
    final source = image_lib.decodeImage(await file.readAsBytes());
    if (source == null) return Response.notFound('image unavailable');
    final x1 = sample.bbox[0];
    final y1 = sample.bbox[1];
    final x2 = sample.bbox[2];
    final y2 = sample.bbox[3];
    final faceWidth = x2 - x1;
    final faceHeight = y2 - y1;
    if (faceWidth <= 0 || faceHeight <= 0) {
      return Response.notFound('invalid face bounds');
    }
    final padding = (faceWidth > faceHeight ? faceWidth : faceHeight) * 0.4;
    final left = (x1 - padding).floor().clamp(0, source.width - 1);
    final top = (y1 - padding).floor().clamp(0, source.height - 1);
    final right = (x2 + padding).ceil().clamp(left + 1, source.width);
    final bottom = (y2 + padding).ceil().clamp(top + 1, source.height);
    var cropped = image_lib.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    if (cropped.width > 360 || cropped.height > 360) {
      cropped = image_lib.copyResize(
        cropped,
        width: cropped.width >= cropped.height ? 360 : null,
        height: cropped.height > cropped.width ? 360 : null,
        interpolation: image_lib.Interpolation.average,
      );
    }
    return Response.ok(
      image_lib.encodeJpg(cropped, quality: 86),
      headers: {
        'content-type': 'image/jpeg',
        'cache-control': 'private, max-age=3600',
      },
    );
  }

  Response _badRequest(String message) => Response.badRequest(
    body: jsonEncode({'ok': false, 'error': message}),
    headers: _jsonHeaders,
  );

  Future<Response> _onIndexDescription(Request req) async {
    final id = req.url.queryParameters['id'];
    if (id == null || id.isEmpty) {
      return Response.badRequest(body: 'missing id');
    }
    final description = await photoIndex.backend.describe(id);
    if (description == null) return Response.notFound('photo not indexed');
    return Response.ok(jsonEncode(description.toJson()), headers: _jsonHeaders);
  }

  /// 人工标注：标记照片为某类别（重复/低画质/广告/截图等）→ hidden，不再显示。
  Future<Response> _onAnnotate(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final id = body['id'] as String?;
      final reason = body['reason'] as String?;
      if (id == null || reason == null) {
        return Response.badRequest(
          body: jsonEncode({'ok': false, 'error': 'missing id/reason'}),
          headers: _jsonHeaders,
        );
      }
      await photoIndex.annotate(id, reason);
      return Response.ok(jsonEncode({'ok': true}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'ok': false, 'error': '$e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// 筛选播放：CLIP 文本搜索 → photos.setFilter，app 轮播只播匹配的。
  /// 类别/主题/匹配都走这里（"猫"/"海边"/"证件照" → CLIP 语义匹配）。
  Future<Response> _onFilter(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final q = (body['q'] as String?)?.trim() ?? '';
      if (q.isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'ok': false, 'error': 'missing q'}),
          headers: _jsonHeaders,
        );
      }
      final ids = await photoIndex.searchText(q);
      photos.setFilter(ids);
      return Response.ok(
        jsonEncode({'count': ids.length, 'query': q, 'ok': true}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'ok': false, 'error': '$e'}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _onFilterClear(Request req) async {
    photos.clearFilter();
    return Response.ok(jsonEncode({'ok': true}), headers: _jsonHeaders);
  }

  /// 代理向量搜索到 daemon search_server（localhost:8781）。
  /// web 控制台只调 control_server（8780），由这里转发，避免跨端口。
  Future<Response> _proxySearch(Request req, String kind) async {
    try {
      final resp = await http.get(
        Uri.parse('http://localhost:8781/api/search/$kind?${req.url.query}'),
      );
      return Response(resp.statusCode, body: resp.body, headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': '搜索服务不可用: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// 读 NAS 配置：密码不返回，仅告知是否已设置（前端留空=不改）。
  Future<Response> _onGetConfig(Request req) async {
    final c = configService.config;
    return Response.ok(
      jsonEncode({
        'nasEnabled': c.nasEnabled,
        'nasWebdavUrl': c.nasWebdavUrl,
        'nasWebdavUser': c.nasWebdavUser,
        'hasPassword': c.nasWebdavPassword.isNotEmpty,
        'nasRemoteDir': c.nasRemoteDir,
        'nasFilterEnabled': c.nasFilterEnabled,
        'nasFilterKeywords': c.nasFilterKeywords,
        'dedupEnabled': c.dedupEnabled,
        'dedupPHashThreshold': c.dedupPHashThreshold,
        'nasFilterMinBytes': c.nasFilterMinBytes,
        'heicEnabled': c.heicEnabled,
        'vlmEnabled': c.vlmEnabled,
        'vlmModel': c.vlmModel,
        'ollamaUrl': c.ollamaUrl,
        'indexStatus': photoIndex.indexStatus,
      }),
      headers: _jsonHeaders,
    );
  }

  /// 保存 NAS 配置并即时生效。只认白名单 NAS 字段（防误覆盖 photoDir 等）；
  /// 密码空串=不改。复刻桌面设置页 _save() 的 save→configure→applyNasConfig 链。
  Future<Response> _onPutConfig(Request req) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response.badRequest(
        body: jsonEncode({'ok': false, 'message': '请求体不是合法 JSON'}),
        headers: _jsonHeaders,
      );
    }
    try {
      final c = configService.config;
      if (body['nasEnabled'] is bool) c.nasEnabled = body['nasEnabled'] as bool;
      if (body['nasWebdavUrl'] is String) {
        c.nasWebdavUrl = (body['nasWebdavUrl'] as String).trim();
      }
      if (body['nasWebdavUser'] is String) {
        c.nasWebdavUser = (body['nasWebdavUser'] as String).trim();
      }
      final pwd = body['nasWebdavPassword'];
      if (pwd is String && pwd.isNotEmpty) c.nasWebdavPassword = pwd;
      if (body['nasRemoteDir'] is String) {
        c.nasRemoteDir = (body['nasRemoteDir'] as String).trim();
      }
      if (body['nasFilterEnabled'] is bool) {
        c.nasFilterEnabled = body['nasFilterEnabled'] as bool;
      }
      final kws = body['nasFilterKeywords'];
      if (kws is List) {
        c.nasFilterKeywords = kws
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
      if (body['dedupEnabled'] is bool) {
        c.dedupEnabled = body['dedupEnabled'] as bool;
      }
      if (body['dedupPHashThreshold'] is int) {
        c.dedupPHashThreshold = body['dedupPHashThreshold'] as int;
      }
      if (body['nasFilterMinBytes'] is int) {
        c.nasFilterMinBytes = body['nasFilterMinBytes'] as int;
      }
      if (body['heicEnabled'] is bool) {
        c.heicEnabled = body['heicEnabled'] as bool;
        photos.heicEnabled = c.heicEnabled;
      }
      if (body['vlmEnabled'] is bool) c.vlmEnabled = body['vlmEnabled'] as bool;
      if (body['vlmModel'] is String) {
        c.vlmModel = (body['vlmModel'] as String).trim();
      }
      if (body['ollamaUrl'] is String) {
        c.ollamaUrl = (body['ollamaUrl'] as String).trim();
      }
      await configService.save();
      final ns = nas;
      if (ns is NasPhotoSource) {
        ns.configure(
          url: c.nasWebdavUrl,
          user: c.nasWebdavUser,
          password: c.nasWebdavPassword,
          remoteDir: c.nasRemoteDir,
        );
      }
      // applyNasConfig 内部写 filter 字段到 nas 实例，并按 nasEnabled 决定是否
      // 真连（fire-and-forget）；真实 nasStatus 变化靠 CommandService 的监听广播。
      await photos.applyNasConfig(c, nas);
      photoIndex.applyConfig(c);
      return Response.ok(jsonEncode({'ok': true}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'ok': false, 'message': '$e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// 测试连接：用请求体临时建探针 ping，不落盘。密码空=用已保存值。
  /// 业务失败也返回 200，前端按 ok 字段判断。
  Future<Response> _onTestConfig(Request req) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response.ok(
        jsonEncode({'ok': false, 'message': '请求体不是合法 JSON'}),
        headers: _jsonHeaders,
      );
    }
    final c = configService.config;
    final pwdRaw = body['nasWebdavPassword'];
    final pwd = (pwdRaw is String && pwdRaw.isNotEmpty)
        ? pwdRaw
        : c.nasWebdavPassword;
    final probe = NasPhotoSource()
      ..configure(
        url: (body['nasWebdavUrl'] as String? ?? c.nasWebdavUrl).trim(),
        user: (body['nasWebdavUser'] as String? ?? c.nasWebdavUser).trim(),
        password: pwd,
        remoteDir: (body['nasRemoteDir'] as String? ?? c.nasRemoteDir).trim(),
      );
    try {
      await probe.ping();
      return Response.ok(
        jsonEncode({'ok': true, 'message': '连接成功'}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.ok(
        jsonEncode({'ok': false, 'message': '连接失败：$e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// 文件名清洗 + 重名加时间戳，防止覆盖和路径穿越。
  static String _uniquePath(String dir, String filename) {
    var name = p.basename(filename).replaceAll(RegExp(r'[^\w.\-一-龥]'), '_');
    if (name.isEmpty || name.startsWith('.')) name = 'photo$name';
    if (File(p.join(dir, name)).existsSync()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      name = '${p.basenameWithoutExtension(name)}_$stamp${p.extension(name)}';
    }
    return p.join(dir, name);
  }

  void _broadcastState() => broadcast(encodeState(commands.currentState()));

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
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
