import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'package:smart_frame/features/photos/domain/nas_filter.dart';
import 'package:smart_frame/features/photos/application/photo_service.dart';

/// NAS 图源抽象：列出远程图片引用、按引用下载。
/// 真实实现是 [NasPhotoSource]（WebDAV）；测试可用 fake 替换。
/// 错误不在内部吞掉，异常原样抛给调用方（PhotoService 的降级逻辑）。
abstract class NasSource {
  /// 递归列出远程目录下的全部图片引用。
  Future<List<NasPhotoRef>> listPhotos();

  /// 把远程文件 [remotePath] 下载到本地 [savePath]。
  Future<void> downloadTo(String remotePath, String savePath);

  /// 上一次 listPhotos 中被过滤规则排除的数量（无过滤能力的实现恒为 0）。
  int get lastFilteredCount => 0;
}

/// NAS 上一张图片的引用：只存远程路径与元信息，不预下载，按需拉取。
class NasPhotoRef {
  NasPhotoRef({required this.path, required this.size, this.mtime});

  /// WebDAV 远程路径（如 /photo/sub/c.jpg）
  final String path;

  /// 文件大小（字节）
  final int size;

  /// 最后修改时间（服务器未提供时为 null）
  final DateTime? mtime;

  /// 文件名（path 的最后一段）
  String get name => path.split('/').last;
}

/// NAS 相册来源：封装 webdav_client，负责连接测试、递归列出图片、按引用下载。
///
/// 错误不在内部吞掉：ping/listPhotos/downloadTo 的异常原样抛出，
/// 由调用方（PhotoService 的降级逻辑）捕获处理。
class NasPhotoSource implements NasSource {
  webdav.Client? _client;
  String _remoteDir = '';

  /// 截图过滤开关与过滤关键词，默认值与 AppConfig 保持一致；
  /// 由上层在应用配置时写入（见 PhotoService.applyNasConfig）。
  bool filterEnabled = true;
  List<String> filterKeywords = const ['截图', 'screenshot', '屏幕快照', '收集'];

  /// 小于此字节数的文件视为缩略图/图标排除（0 = 不限）
  int filterMinBytes = 0;

  int _filteredCount = 0;

  /// 上一次 listPhotos 中被截图过滤规则排除的数量（规格：被过滤数量计入状态）
  @override
  int get lastFilteredCount => _filteredCount;

  /// 配置 WebDAV 连接参数；重复调用会重建客户端。
  void configure({
    required String url,
    required String user,
    required String password,
    required String remoteDir,
  }) {
    final client = webdav.newClient(url, user: user, password: password);
    client.setConnectTimeout(8000); // 毫秒
    client.setReceiveTimeout(60000);
    _client = client;
    _remoteDir = remoteDir;
  }

  /// 连接测试：凭据错误 / 超时 / 不可达时抛异常。
  Future<void> ping() async {
    final client = _client;
    if (client == null) throw StateError('NasPhotoSource 未 configure');
    await client.ping();
  }

  /// 递归列出远程目录下的全部图片（按扩展名 + 截图规则过滤）。
  /// 未 configure 或 remoteDir 为空时返回空列表。
  @override
  Future<List<NasPhotoRef>> listPhotos() async {
    final client = _client;
    if (client == null || _remoteDir.isEmpty) return [];
    final result = <NasPhotoRef>[];
    _filteredCount = 0; // 每次列出重新计数
    await _listInto(client, _remoteDir, result);
    return result;
  }

  Future<void> _listInto(
    webdav.Client client,
    String dir,
    List<NasPhotoRef> out,
  ) async {
    for (final entry in await client.readDir(dir)) {
      final path = entry.path;
      if (path == null) continue;
      // @eaDir（群晖缩略图目录）整棵跳过，不递归（省 PROPFIND）
      if (path.split('/').any((s) => s == '@eaDir')) {
        _filteredCount++;
        continue;
      }
      if (entry.isDir == true) {
        await _listInto(client, path, out);
        continue;
      }
      // 只认图片扩展名（含 HEIC，HEIC 由 PhotoService.fileFor 转换）
      final ext = p.extension(path).toLowerCase();
      final isImage =
          PhotoService.imageExts.contains(ext) ||
          PhotoService.heicExts.contains(ext);
      if (!isImage) continue;
      if (!nasPhotoAllowed(
        path,
        enabled: filterEnabled,
        keywords: filterKeywords,
        size: entry.size ?? 0,
        minBytes: filterMinBytes,
      )) {
        _filteredCount++;
        continue;
      }
      out.add(
        NasPhotoRef(path: path, size: entry.size ?? 0, mtime: entry.mTime),
      );
    }
  }

  /// 把远程文件 [remotePath] 下载到本地 [savePath]。
  @override
  Future<void> downloadTo(String remotePath, String savePath) async {
    final client = _client;
    if (client == null) throw StateError('NasPhotoSource 未 configure');
    await client.read2File(remotePath, savePath);
  }
}
