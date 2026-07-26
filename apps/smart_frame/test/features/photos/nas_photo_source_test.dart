import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/photos/data/nas_photo_source.dart';

/// 端到端：用 dart:io HttpServer 起假 WebDAV 服务器（参考 control_server_test
/// 起真实服务器的模式），验证 NasPhotoSource 的 ping / 递归列目录 / 下载 / 降级分支。
///
/// 假服务器目录结构：
///   /photo/           a.jpg(1000B)、b.png(2000B)、sub/
///   /photo/sub/       Screenshot_1.png(500B，应被过滤)、c.jpg(3000B)
void main() {
  /// 假 NAS 上的文件：远程路径 → 字节数
  const files = {
    '/photo/a.jpg': 1000,
    '/photo/b.png': 2000,
    '/photo/sub/Screenshot_1.png': 500,
    '/photo/sub/c.jpg': 3000,
  };

  /// 假 NAS 上的目录：远程路径 → 直接子项 href 列表
  const dirs = {
    '/photo/': ['/photo/a.jpg', '/photo/b.png', '/photo/sub/'],
    '/photo/sub/': ['/photo/sub/Screenshot_1.png', '/photo/sub/c.jpg'],
  };

  late HttpServer server;

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  /// multistatus XML（细节按 webdav_client 1.2.2 真实解析要求微调过简报样例：
  /// 每个 propstat 必须带 status 200，且第一条 response 必须是目录自身）
  String multistatus(String selfHref, List<String> children) {
    String collection(String href) =>
        '<D:response><D:href>$href</D:href><D:propstat><D:prop>'
        '<D:resourcetype><D:collection/></D:resourcetype>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';
    String file(String href, int size) =>
        '<D:response><D:href>$href</D:href><D:propstat><D:prop>'
        '<D:resourcetype/><D:getcontentlength>$size</D:getcontentlength>'
        '<D:getlastmodified>Thu, 01 Jun 2023 12:00:00 GMT</D:getlastmodified>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';
    final buf = StringBuffer(collection(selfHref));
    for (final child in children) {
      buf.write(
        child.endsWith('/') ? collection(child) : file(child, files[child]!),
      );
    }
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<D:multistatus xmlns:D="DAV:">$buf</D:multistatus>';
  }

  Future<void> handle(HttpRequest request) async {
    await request.drain<void>(); // PROPFIND 带请求体，先排空再响应
    final path = request.uri.path;
    final response = request.response;
    if (request.method == 'OPTIONS') {
      response.statusCode = 200;
    } else if (request.method == 'PROPFIND') {
      final children = dirs[path];
      if (children == null) {
        response.statusCode = 404;
      } else {
        response.statusCode = 207;
        response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        response.write(multistatus(path, children));
      }
    } else if (request.method == 'GET') {
      final size = files[path];
      if (size == null) {
        response.statusCode = 404;
      } else {
        response.statusCode = 200;
        response.contentLength = size;
        response.add(List.filled(size, 0x61));
      }
    } else {
      response.statusCode = 405;
    }
    await response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('ping 成功，listPhotos 递归列出 3 张图片（截图被默认关键词过滤）', () async {
    final source = NasPhotoSource()
      ..configure(
        url: baseUrl(),
        user: 'u',
        password: 'p',
        remoteDir: '/photo',
      );
    await source.ping();

    final refs = await source.listPhotos();
    expect(refs, hasLength(3));
    final byPath = {for (final r in refs) r.path: r};
    expect(byPath.keys.toSet(), {
      '/photo/a.jpg',
      '/photo/b.png',
      '/photo/sub/c.jpg',
    });
    expect(byPath['/photo/a.jpg']!.size, 1000);
    expect(byPath['/photo/b.png']!.size, 2000);
    expect(byPath['/photo/sub/c.jpg']!.size, 3000);
    expect(byPath['/photo/sub/c.jpg']!.name, 'c.jpg');
    expect(byPath['/photo/a.jpg']!.mtime, isNotNull);
    // Screenshot_1.png 命中截图规则，不进列表，且被过滤数量计入 lastFilteredCount
    expect(refs.any((r) => r.path.contains('Screenshot')), isFalse);
    expect(source.lastFilteredCount, 1);
  });

  test('downloadTo 把远程文件写盘且长度正确', () async {
    final source = NasPhotoSource()
      ..configure(
        url: baseUrl(),
        user: 'u',
        password: 'p',
        remoteDir: '/photo',
      );
    final tmp = await Directory.systemTemp.createTemp('nas_download_test');
    try {
      final savePath = '${tmp.path}/a.jpg';
      await source.downloadTo('/photo/a.jpg', savePath);
      final saved = File(savePath);
      expect(saved.existsSync(), isTrue);
      expect(await saved.length(), 1000);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('401 响应时 ping 抛异常（不内部吞掉）', () async {
    final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    denied.listen((request) async {
      request.response.statusCode = 401; // 不带 www-authenticate，客户端直接抛错
      await request.response.close();
    });
    try {
      final source = NasPhotoSource()
        ..configure(
          url: 'http://127.0.0.1:${denied.port}',
          user: 'bad',
          password: 'bad',
          remoteDir: '/photo',
        );
      await expectLater(source.ping(), throwsA(anything));
    } finally {
      await denied.close(force: true);
    }
  });

  test('未 configure 或 remoteDir 为空时 listPhotos 返回空', () async {
    expect(await NasPhotoSource().listPhotos(), isEmpty);

    final configured = NasPhotoSource()
      ..configure(url: baseUrl(), user: 'u', password: 'p', remoteDir: '');
    expect(await configured.listPhotos(), isEmpty);
  });
}
