import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:smart_frame/features/photos/data/nas_photo_source.dart';

/// HTTP 照片源（展示节点用）：从计算节点 control_server 拉照片列表 + 字节，
/// 实现 [NasSource] 抽象——PhotoService 持有抽象，零改动即可切换数据源。
///
/// 计算节点的本地照片 + NAS 照片统一经 HTTP 提供（id = 远程/本地 path），
/// 展示节点不连 NAS、不需要 heif-convert（计算端已转 jpg）。
class HttpPhotoSource implements NasSource {
  HttpPhotoSource(this.baseUrl);

  /// 计算节点根 URL，如 http://192.168.1.9:8780
  final String baseUrl;

  final int _lastFiltered = 0;

  @override
  int get lastFilteredCount => _lastFiltered;

  @override
  Future<List<NasPhotoRef>> listPhotos() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/photos/list'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (body['photos'] as List).cast<Map<String, dynamic>>();
    // id（计算节点 PhotoItem.id）= 远程 path 或本地文件路径，作 NasPhotoRef.path
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
      Uri.parse(
        '$baseUrl/api/photos/file?id=${Uri.encodeComponent(remotePath)}',
      ),
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP 下载失败 ${resp.statusCode}: $remotePath');
    }
    await Directory(p.dirname(savePath)).create(recursive: true);
    await File(savePath).writeAsBytes(resp.bodyBytes);
  }
}
