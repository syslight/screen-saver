import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:smart_frame/core/config/app_config.dart';
import 'package:smart_frame/features/photos/data/nas_photo_source.dart';

/// 相册项：本地文件或 NAS 远程引用，二者必居其一。
class PhotoItem {
  PhotoItem._({
    required this.id,
    required this.name,
    this.local,
    this.nas,
    this.modifiedAt,
  });

  /// 本地文件项（id 为文件路径）
  factory PhotoItem.fromLocal(File file) {
    DateTime? modifiedAt;
    try {
      modifiedAt = file.lastModifiedSync();
    } catch (_) {}
    return PhotoItem._(
      id: file.path,
      name: p.basename(file.path),
      local: file,
      modifiedAt: modifiedAt,
    );
  }

  /// NAS 引用项（id 为远程路径）
  factory PhotoItem.fromNas(NasPhotoRef ref) => PhotoItem._(
    id: ref.path,
    name: ref.name,
    nas: ref,
    modifiedAt: ref.mtime,
  );

  /// 唯一标识：本地为文件路径，NAS 为远程路径
  final String id;

  /// 展示名（文件名）
  final String name;

  /// 本地文件（仅本地项非空）
  final File? local;

  /// NAS 引用（仅 NAS 项非空）
  final NasPhotoRef? nas;

  /// 文件最后修改时间；真实拍摄时间优先由照片索引元数据提供。
  final DateTime? modifiedAt;

  bool get isNas => nas != null;
}

/// 相册：扫描本地目录、聚合 NAS 图源（带 LRU 磁盘缓存）、轮播、手动切换。
/// 本地 30 秒定时重扫（手机上传后自动出现）；NAS 列表独立每 300 秒刷新。
/// NAS 故障静默降级：只落 nasStatus，不抛异常、不影响本地相册。
class PhotoService extends ChangeNotifier {
  PhotoService(
    this.photoDir, {
    this.cacheDir = '',
    this.cacheLimitBytes = defaultCacheLimitBytes,
    this.playbackStatePath = '',
  });

  static const imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'];

  /// HEIC/HEIF 扩展名：桌面 Flutter/Skia 不原生解码，fileFor 需调系统
  /// heif-convert 转 jpg 后才能显示。
  static const heicExts = ['.heic', '.heif'];

  /// NAS 缓存默认上限：500MB
  static const defaultCacheLimitBytes = 500 * 1024 * 1024;

  String photoDir;

  /// NAS 缓存目录；为空表示未初始化，此时 NAS 项不可 fileFor
  final String cacheDir;

  /// 是否启用 HEIC 转换（false 或 heif-convert 不可用时 HEIC 跳过）
  bool heicEnabled = true;

  /// 系统 heif-convert 是否可用（启动时 [detectHeifConvert] 检测）
  static bool heicConvertAvailable = false;

  /// 检测 heif-convert 是否在 PATH（桌面 Flutter 不原生解 HEIC，需此工具）
  static Future<void> detectHeifConvert() async {
    try {
      final r = await Process.run('which', ['heif-convert']);
      heicConvertAvailable = r.exitCode == 0;
    } catch (_) {
      heicConvertAvailable = false;
    }
  }

  /// 缓存上限（字节），超出后按 lastModified 最旧先淘汰
  final int cacheLimitBytes;

  /// 轮播进度文件；为空时不持久化（单测/临时实例可关闭）。
  final String playbackStatePath;

  List<PhotoItem> photos = [];
  List<File> _localFiles = [];
  List<NasPhotoRef> _nasRefs = [];
  int _index = 0;

  /// 被去重/质量规则隐藏的 photo id（播放跳过，不进 playable 视图）
  final Set<String> _hiddenIds = {};

  /// 筛选白名单（「放猫的」等）；null = 不筛选，播全部 playable
  Set<String>? _filterIds;

  NasSource? _nas;
  bool _nasEnabled = false;
  String _nasStatus = '未启用';

  /// 进行中的下载（同一远程路径并发只下载一次）
  final Map<String, Future<File?>> _downloading = {};

  Timer? _slideshowTimer;
  Timer? _rescanTimer;
  Timer? _nasTimer;
  Timer? _persistTimer;
  int _slideshowSeconds = 0;

  /// 启动时恢复的 photo id。NAS 首次列表尚未返回时保留，避免被本地首张覆盖。
  String? _pendingResumeId;

  PhotoItem? get current {
    final p = playable;
    if (p.isEmpty) return null;
    return p[_index.clamp(0, p.length - 1)];
  }

  String get currentName {
    if (playable.isEmpty) {
      return photos.isEmpty ? '（相册为空）' : '（全部已过滤）';
    }
    return current!.name;
  }

  /// 可播放视图：photos 减去 _hiddenIds；若有 [_filterIds] 再取交集（筛选模式）。
  /// [_index] 是此视图的下标。
  List<PhotoItem> get playable {
    final base = _hiddenIds.isEmpty
        ? photos
        : photos.where((p) => !_hiddenIds.contains(p.id)).toList();
    final f = _filterIds;
    return f == null ? base : base.where((p) => f.contains(p.id)).toList();
  }

  /// 被去重/质量规则隐藏的数量
  int get hiddenCount => _hiddenIds.isEmpty
      ? 0
      : photos.where((p) => _hiddenIds.contains(p.id)).length;

  /// 标记隐藏（去重/质量规则用）；保持当前张不变（除非当前被隐藏）
  void setHidden(Iterable<String> ids) {
    if (ids.isEmpty) return;
    final curId = current?.id;
    _hiddenIds.addAll(ids);
    _realignIndex(curId);
    notifyListeners();
  }

  void clearHidden() {
    if (_hiddenIds.isEmpty) return;
    final curId = current?.id;
    _hiddenIds.clear();
    _realignIndex(curId);
    notifyListeners();
  }

  /// 筛选播放（「放猫的」）：只播 [ids] 内的照片；传 null 清除筛选播全部。
  void setFilter(Set<String>? ids) {
    final curId = current?.id;
    _filterIds = ids;
    _realignIndex(curId);
    notifyListeners();
  }

  void clearFilter() => setFilter(null);

  /// 按 [currentId] 在 playable 中重定位 [_index]（photos/hidden 变化后调用）
  void _realignIndex(String? currentId) {
    final p = playable;
    if (p.isEmpty) {
      _index = 0;
      return;
    }
    final resumeId = _pendingResumeId;
    if (resumeId != null) {
      final resumeIndex = p.indexWhere((item) => item.id == resumeId);
      if (resumeIndex >= 0) {
        _index = resumeIndex;
        _pendingResumeId = null;
        return;
      }
    }
    if (currentId != null) {
      final i = p.indexWhere((item) => item.id == currentId);
      _index = i >= 0 ? i : 0;
    } else {
      _index = 0;
    }
  }

  /// NAS 状态：未启用 / 未配置 / 已连接 N 张 / 连接失败
  String get nasStatus => _nasStatus;

  Future<void> init() async {
    await _loadPlaybackState();
    await rescan();
    _rescanTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(rescan()),
    );
  }

  Future<void> setDir(String dir) async {
    if (dir == photoDir) return;
    photoDir = dir;
    _index = 0;
    _pendingResumeId = null;
    await rescan();
    _schedulePersistCurrent();
  }

  void startSlideshow(int seconds) {
    _slideshowSeconds = seconds;
    _slideshowTimer?.cancel();
    if (seconds > 0) {
      _slideshowTimer = Timer.periodic(
        Duration(seconds: seconds),
        (_) => _advance(1, user: false),
      );
    }
  }

  /// 重扫本地目录（只扫本地，NAS 列表由 _refreshNas 独立维护）。
  Future<void> rescan() async {
    try {
      final dir = Directory(photoDir);
      if (!await dir.exists()) {
        if (_localFiles.isNotEmpty) {
          _localFiles = [];
          _rebuildPhotos();
          notifyListeners();
        }
        return;
      }
      final found = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            imageExts.contains(p.extension(entity.path).toLowerCase())) {
          found.add(entity);
        }
      }
      found.sort((a, b) => a.path.compareTo(b.path));
      _localFiles = found;
      _rebuildPhotos();
      notifyListeners();
    } catch (_) {
      // 目录不可读等异常不打断界面
    }
  }

  /// 配置 NAS 来源并立即触发一次刷新；之后每 300 秒自动刷新。
  /// 首次刷新是 fire-and-forget（NAS 不可达时连接超时 8 秒，不得阻塞
  /// 启动与设置保存），完成后由 _refreshNas 内部 notifyListeners 更新状态。
  /// 未启用/未配置时清空 NAS 列表；失败只落 nasStatus，不抛异常。
  Future<void> applyNasConfig(
    AppConfig config,
    NasSource nas, {
    bool forceEnabled = false,
  }) async {
    // 过滤配置先写入，再触发 listPhotos
    if (nas is NasPhotoSource) {
      nas.filterEnabled = config.nasFilterEnabled;
      nas.filterKeywords = config.nasFilterKeywords;
      nas.filterMinBytes = config.nasFilterMinBytes;
    }
    _nas = nas;
    _nasEnabled =
        forceEnabled || (config.nasEnabled && config.nasRemoteDir.isNotEmpty);
    if (_nasEnabled) {
      _nasStatus = '连接中';
    } else if (!config.nasEnabled) {
      _nasStatus = '未启用';
    } else if (config.nasRemoteDir.isEmpty) {
      _nasStatus = '未配置';
    }
    _nasTimer?.cancel();
    if (_nasEnabled) {
      // 首次刷新不等待：NAS 关机时连接超时 8 秒，阻塞会黑屏/冻结设置页；
      // 刷新完成后由 _refreshNas 内部 notifyListeners 更新状态与列表
      unawaited(_refreshNas());
      _nasTimer = Timer.periodic(
        const Duration(seconds: 300),
        (_) => unawaited(_refreshNas()),
      );
      unawaited(_evictCache()); // 启动（应用配置）时做一次淘汰检查
    } else {
      if (_nasRefs.isNotEmpty) {
        _nasRefs = [];
        _rebuildPhotos();
      }
      _finishPendingResume();
      // 未启用/未配置时即使列表没变，状态文案也可能变了，必须刷新 UI
      notifyListeners();
    }
  }

  Future<void> _refreshNas() async {
    final nas = _nas;
    if (nas == null) return;
    var loaded = false;
    try {
      final refs = await nas.listPhotos();
      refs.sort((a, b) => a.name.compareTo(b.name));
      _nasRefs = refs;
      // 被过滤数量计入状态（规格要求），M=0 时不带括号
      final filtered = nas.lastFilteredCount;
      _nasStatus = filtered > 0
          ? '已连接 ${refs.length} 张（已过滤 $filtered）'
          : '已连接 ${refs.length} 张';
      loaded = true;
    } catch (_) {
      // 静默降级：保留已知引用（已缓存的仍可展示），仅更新状态
      _nasStatus = '连接失败';
    }
    _rebuildPhotos();
    if (loaded) _finishPendingResume();
    notifyListeners();
  }

  /// 取可用于展示的文件：本地直接返回；NAS 先查缓存（命中直接返回），
  /// 未命中则下载入缓存后返回。缓存目录未初始化或下载失败时返回 null。
  Future<File?> fileFor(PhotoItem item) {
    final local = item.local;
    if (local != null) return Future.value(local);
    final ref = item.nas;
    if (ref == null || _nas == null || cacheDir.isEmpty) {
      return Future.value(null);
    }
    final cached = cachedFileFor(item);
    if (cached != null) {
      _touch(cached); // 命中即刷新访问时间，LRU 按它淘汰
      return Future.value(cached);
    }
    final inFlight = _downloading[ref.path];
    if (inFlight != null) return inFlight;
    // 同一远程路径并发只下载一次；完成后从表里移除
    final future = _download(ref).whenComplete(() {
      _downloading.remove(ref.path);
    });
    _downloading[ref.path] = future;
    return future;
  }

  /// 按稳定照片 ID 取文件。人物确认等索引驱动场景可能早于 NAS 全量列表完成，
  /// 此时允许直接按索引中的远程路径下载，不必等待数万张照片递归扫描完毕。
  Future<File?> fileForId(String id) async {
    for (final item in photos) {
      if (item.id == id) return fileFor(item);
    }
    final local = File(id);
    if (await local.exists()) return local;
    final ext = p.extension(id).toLowerCase();
    final supported = imageExts.contains(ext) || heicExts.contains(ext);
    if (!_nasEnabled || _nas == null || !supported) return null;
    return fileFor(PhotoItem.fromNas(NasPhotoRef(path: id, size: 0)));
  }

  /// 纯查询缓存是否已存在（不触发下载），UI 同步判断用。
  File? cachedFileFor(PhotoItem item) {
    final local = item.local;
    if (local != null) return local;
    final ref = item.nas;
    if (ref == null || cacheDir.isEmpty) return null;
    final file = File(_cachePathFor(ref.path));
    return file.existsSync() ? file : null;
  }

  /// 预取下一张 NAS 图，保证轮播间隔内不卡。
  void prefetchNext() {
    final p = playable;
    if (p.isEmpty) return;
    final nextItem = p[(_index + 1) % p.length];
    if (nextItem.isNas) unawaited(fileFor(nextItem));
  }

  Future<File?> _download(NasPhotoRef ref) async {
    final path = _cachePathFor(ref.path);
    final isHeic = heicExts.contains(p.extension(ref.path).toLowerCase());
    try {
      await Directory(cacheDir).create(recursive: true);
      if (isHeic) {
        // 桌面不原生解 HEIC：下载到临时再 heif-convert 转 jpg；不可用则跳过
        if (!heicEnabled || !heicConvertAvailable) return null;
        final tmp = '$path.heic.tmp';
        await _nas!.downloadTo(ref.path, tmp);
        final res = await Process.run('heif-convert', [tmp, path]);
        try {
          await File(tmp).delete();
        } catch (_) {}
        if (res.exitCode != 0 || !await File(path).exists()) return null;
      } else {
        await _nas!.downloadTo(ref.path, path);
        if (!await File(path).exists()) return null;
      }
      await _evictCache(keepPath: path);
      return File(path);
    } catch (e) {
      // 单张下载失败：清理可能残留的部分文件（避免 cachedFileFor 误命中
      // 半截文件导致永久黑块），记日志后跳过该张（视同不存在）
      try {
        await File(path).delete();
      } catch (_) {}
      try {
        await File('$path.heic.tmp').delete();
      } catch (_) {}
      debugPrint('NAS 下载失败: ${ref.path}, $e');
      return null;
    }
  }

  /// 缓存文件名 = sha256(远程路径) 前 16 位 + 扩展名（HEIC 统一以 .jpg 缓存，
  /// 下载时由 heif-convert 转换；桌面 Flutter 不原生解 HEIC）。
  String _cachePathFor(String remotePath) {
    final hash = sha256
        .convert(utf8.encode(remotePath))
        .toString()
        .substring(0, 16);
    final ext = p.extension(remotePath).toLowerCase();
    final cacheExt = heicExts.contains(ext) ? '.jpg' : ext;
    return p.join(cacheDir, '$hash$cacheExt');
  }

  void _touch(File file) {
    try {
      file.setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  /// LRU 淘汰：缓存总量超上限时，按 lastModified 最旧先删。
  /// [keepPath] 指向的文件（刚下载写入的）永不淘汰，避免单张超限时被误删。
  Future<void> _evictCache({String? keepPath}) async {
    if (cacheDir.isEmpty) return;
    try {
      final dir = Directory(cacheDir);
      if (!await dir.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          files.add(entity);
          total += await entity.length();
        }
      }
      if (total <= cacheLimitBytes) return;
      final byAge = <(File, DateTime)>[
        for (final f in files) (f, await f.lastModified()),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _) in byAge) {
        if (total <= cacheLimitBytes) break;
        if (file.path == keepPath) continue; // 永不淘汰刚写入的文件
        total -= await file.length();
        await file.delete();
      }
    } catch (_) {
      // 缓存目录异常不影响相册
    }
  }

  /// 合并本地与 NAS 列表（本地在前按路径排序，NAS 在后按 name 排序），
  /// 并尽量保持当前张不变（按 id 对齐，找不到则回到 0）。
  void _rebuildPhotos() {
    final currentId = current?.id;
    photos = [
      for (final file in _localFiles) PhotoItem.fromLocal(file),
      for (final ref in _nasRefs) PhotoItem.fromNas(ref),
    ];
    _realignIndex(currentId);
  }

  void next() => _advance(1);
  void prev() => _advance(-1);

  void _advance(int delta, {bool user = true}) {
    final p = playable;
    if (p.isEmpty) return;
    if (user) _pendingResumeId = null;
    _index = (_index + delta) % p.length;
    if (_index < 0) _index += p.length;
    if (_pendingResumeId == null) _schedulePersistCurrent();
    notifyListeners();
    // 手动切换后重新开始轮播计时，避免刚切完又跳
    if (user && _slideshowSeconds > 0) startSlideshow(_slideshowSeconds);
  }

  Future<void> _loadPlaybackState() async {
    if (playbackStatePath.isEmpty) return;
    try {
      final file = File(playbackStatePath);
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final id = (json['photoId'] as String?)?.trim();
      if (id != null && id.isNotEmpty) _pendingResumeId = id;
    } catch (_) {
      // 进度文件损坏时从首张开始，不影响相册启动。
    }
  }

  void _finishPendingResume() {
    if (_pendingResumeId == null) return;
    _pendingResumeId = null;
    _schedulePersistCurrent();
  }

  void _schedulePersistCurrent() {
    if (playbackStatePath.isEmpty || current == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistCurrent());
    });
  }

  Future<void> _persistCurrent() async {
    final id = current?.id;
    if (id == null || playbackStatePath.isEmpty) return;
    try {
      final file = File(playbackStatePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'photoId': id,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      // 存储失败不打断轮播。
    }
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _rescanTimer?.cancel();
    _nasTimer?.cancel();
    _persistTimer?.cancel();
    super.dispose();
  }
}
