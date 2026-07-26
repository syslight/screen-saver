import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:smart_frame/features/photos/data/nas_photo_source.dart';

/// HTTP 照片源（展示节点用）：从 home_agent 拉取经去重/隐藏过滤的
/// 照片列表和字节，并复用 [PhotoService] 的本地缓存/轮播逻辑。
///
/// 展示节点只持有节点凭据，不持有 NAS 密码或原始文件路径。
class HttpPhotoSource implements NasSource {
  HttpPhotoSource(
    this.baseUrl, {
    required this.nodeId,
    required this.deviceKey,
  });

  /// home_agent 根 URL，如 http://192.168.1.9:8790
  final String baseUrl;
  final String nodeId;
  final String deviceKey;

  Map<String, String> get _headers => {
    'Authorization': 'Node $nodeId:$deviceKey',
  };

  final int _lastFiltered = 0;

  @override
  int get lastFilteredCount => _lastFiltered;

  @override
  Future<List<NasPhotoRef>> listPhotos() async {
    final list = <Map<String, dynamic>>[];
    var offset = 0;
    const limit = 5000;
    while (true) {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/media/photos?limit=$limit&offset=$offset'),
        headers: _headers,
      );
      if (resp.statusCode != 200) {
        throw Exception('照片目录读取失败 ${resp.statusCode}');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final page = (body['photos'] as List).cast<Map<String, dynamic>>();
      list.addAll(page);
      offset += page.length;
      if (page.isEmpty || offset >= (body['total'] as int? ?? offset)) break;
    }
    // id 是服务端不透明 media id，可安全用作 NasPhotoRef.path。
    return [
      for (final e in list)
        NasPhotoRef(
          path: e['id'] as String,
          size: 0,
          mtime: e['modifiedAt'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(e['modifiedAt'] as int),
        ),
    ];
  }

  @override
  Future<void> downloadTo(String remotePath, String savePath) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/media/photos/$remotePath/content'),
      headers: _headers,
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP 下载失败 ${resp.statusCode}: $remotePath');
    }
    await Directory(p.dirname(savePath)).create(recursive: true);
    await File(savePath).writeAsBytes(resp.bodyBytes);
  }
}
