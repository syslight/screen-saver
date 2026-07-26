import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:smart_frame/core/config/app_config.dart';
import 'package:smart_frame/features/photos/data/nas_photo_source.dart';
import 'package:smart_frame/features/photos/application/photo_service.dart';

/// 假 NAS 图源：返回固定 ref 列表；downloadTo 把固定字节写入 savePath 并计数。
class FakeNasSource implements NasSource {
  FakeNasSource({List<NasPhotoRef>? refs, List<int>? fileBytes})
    : refs = refs ?? [],
      fileBytes = fileBytes ?? const [1, 2, 3];

  List<NasPhotoRef> refs;
  final List<int> fileBytes;
  bool listThrows = false;

  /// 挂起闸门：非空时 listPhotos 等待其 future（模拟 NAS 不可达但不报错）
  Completer<List<NasPhotoRef>>? listGate;

  /// 下载中断模拟：true 时只写部分字节后抛异常（产生残留部分文件）
  bool downloadThrowsPartial = false;

  /// 报告给上层的被过滤数量（对应真实源的 lastFilteredCount）
  int filteredCount = 0;

  int listCallCount = 0;
  int downloadCount = 0;

  @override
  int get lastFilteredCount => filteredCount;

  @override
  Future<List<NasPhotoRef>> listPhotos() async {
    listCallCount++;
    if (listThrows) throw StateError('NAS 不可达');
    final gate = listGate;
    if (gate != null) return gate.future;
    return List.of(refs);
  }

  @override
  Future<void> downloadTo(String remotePath, String savePath) async {
    downloadCount++;
    if (downloadThrowsPartial) {
      // 模拟写盘中断：只写入部分字节就抛异常
      await File(savePath).writeAsBytes(fileBytes.sublist(0, 1));
      throw StateError('下载中断');
    }
    await File(savePath).writeAsBytes(fileBytes);
  }
}

void main() {
  late Directory photoDir;
  late Directory cacheDir;

  setUp(() async {
    photoDir = await Directory.systemTemp.createTemp('photo_service_test');
    cacheDir = await Directory.systemTemp.createTemp('photo_cache_test');
  });

  tearDown(() async {
    if (await photoDir.exists()) await photoDir.delete(recursive: true);
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });

  Future<File> writeLocal(String name, [List<int>? bytes]) =>
      File(p.join(photoDir.path, name)).writeAsBytes(bytes ?? [1, 2, 3]);

  PhotoService makeService({
    int cacheLimitBytes = 500 * 1024 * 1024,
    String playbackStatePath = '',
  }) => PhotoService(
    photoDir.path,
    cacheDir: cacheDir.path,
    cacheLimitBytes: cacheLimitBytes,
    playbackStatePath: playbackStatePath,
  );

  AppConfig nasConfig({bool enabled = true, String remoteDir = '/photo'}) =>
      AppConfig(nasEnabled: enabled, nasRemoteDir: remoteDir);

  /// applyNasConfig 的首次 NAS 刷新是 fire-and-forget：轮询直到状态达到预期。
  /// 状态赋值与列表重建在 _refreshNas 内同步完成，状态对即列表对。
  Future<void> pumpNasRefresh(
    PhotoService service,
    FakeNasSource nas,
    String status,
  ) async {
    for (var i = 0; i < 200; i++) {
      if (nas.listCallCount > 0 && service.nasStatus == status) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('NAS 刷新未按预期完成：期望「$status」，实际「${service.nasStatus}」');
  }

  test('setHidden 跳过：photos 列表不变，playable/current 跳过', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.png');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    expect(service.photos.length, 2);
    final firstId = service.photos.first.id;
    expect(service.current!.id, firstId);
    service.setHidden([firstId]);
    expect(service.photos.length, 2); // 列表不变
    expect(service.playable.length, 1); // playable 少 1
    expect(service.hiddenCount, 1);
    expect(service.current!.id, isNot(firstId)); // 当前跳到 b
    service.clearHidden();
    expect(service.playable.length, 2);
    expect(service.hiddenCount, 0);
  });

  test('setHidden 全部隐藏：current=null、文案提示、next/prev 不崩', () async {
    await writeLocal('a.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    service.setHidden(service.photos.map((p) => p.id).toList());
    expect(service.playable, isEmpty);
    expect(service.current, isNull);
    expect(service.currentName, '（全部已过滤）');
    service.next(); // 不抛异常
    service.prev();
  });

  test('next/prev 跳过 hidden 并环绕', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.png');
    await writeLocal('c.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    // 隐藏中间的 b.png
    final bId = service.photos.firstWhere((p) => p.name == 'b.png').id;
    service.setHidden([bId]);
    expect(service.playable.map((p) => p.name), ['a.jpg', 'c.jpg']);
    service.next(); // a → c（跳过 b）
    expect(service.current!.name, 'c.jpg');
    service.next(); // c → a（环绕，跳过 b）
    expect(service.current!.name, 'a.jpg');
    service.prev(); // a → c（反向环绕，跳过 b）
    expect(service.current!.name, 'c.jpg');
  });

  test('轮播位置落盘，重启后恢复到上次照片', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.jpg');
    await writeLocal('c.jpg');
    final statePath = p.join(cacheDir.path, 'slideshow_state.json');

    final first = makeService(playbackStatePath: statePath);
    await first.init();
    first.next();
    first.next();
    expect(first.current!.name, 'c.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    first.dispose();

    final restored = makeService(playbackStatePath: statePath);
    addTearDown(restored.dispose);
    await restored.init();
    expect(restored.current!.name, 'c.jpg');
  });

  test('恢复位置会等待 NAS 首次列表，不被本地首张覆盖', () async {
    await writeLocal('local.jpg');
    final statePath = p.join(cacheDir.path, 'slideshow_state.json');
    await File(
      statePath,
    ).writeAsString(jsonEncode({'version': 1, 'photoId': '/photo/b.jpg'}));
    final nas = FakeNasSource(
      refs: [
        NasPhotoRef(path: '/photo/a.jpg', size: 10),
        NasPhotoRef(path: '/photo/b.jpg', size: 10),
      ],
    );
    final service = makeService(playbackStatePath: statePath);
    addTearDown(service.dispose);
    await service.init();
    expect(service.current!.name, 'local.jpg');

    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 2 张');
    expect(service.current!.id, '/photo/b.jpg');
  });

  test('筛选白名单与 hidden 取交集，清除后恢复全部可播放照片', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.jpg');
    await writeLocal('c.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    final ids = {for (final item in service.photos) item.name: item.id};

    service.setHidden([ids['b.jpg']!]);
    service.setFilter({ids['b.jpg']!, ids['c.jpg']!});
    expect(service.playable.map((p) => p.name), ['c.jpg']);
    expect(service.currentName, 'c.jpg');

    service.clearFilter();
    expect(service.playable.map((p) => p.name), ['a.jpg', 'c.jpg']);
  });

  test('空筛选结果安全退化为无当前照片', () async {
    await writeLocal('a.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();

    service.setFilter({});
    expect(service.playable, isEmpty);
    expect(service.current, isNull);
    expect(service.currentName, '（全部已过滤）');
    service.next();
    service.prev();
  });

  test('混合列表：本地在前按 name 排序，NAS 在后按 name 排序', () async {
    await writeLocal('b.jpg');
    await writeLocal('a.jpg');
    final nas = FakeNasSource(
      refs: [
        NasPhotoRef(path: '/photo/d.jpg', size: 10),
        NasPhotoRef(path: '/photo/c.jpg', size: 10),
      ],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 2 张');

    expect(service.photos.map((i) => i.name), [
      'a.jpg',
      'b.jpg',
      'c.jpg',
      'd.jpg',
    ]);
    expect(service.photos.take(2).every((i) => !i.isNas), isTrue);
    expect(service.photos.skip(2).every((i) => i.isNas), isTrue);
    // id：本地为文件路径，NAS 为远程路径
    expect(service.photos[0].id, p.join(photoDir.path, 'a.jpg'));
    expect(service.photos[0].local, isA<File>());
    expect(service.photos[2].id, '/photo/c.jpg');
    expect(service.photos[2].nas!.name, 'c.jpg');
    expect(service.nasStatus, '已连接 2 张');
  });

  test('currentName：本地项返回文件名，NAS 项返回 ref.name，空相册提示不变', () async {
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    expect(service.current, isNull);
    expect(service.currentName, '（相册为空）');

    await writeLocal('a.jpg');
    await service.rescan();
    expect(service.currentName, 'a.jpg');

    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/sub/c.jpg', size: 1)],
    );
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 1 张');
    service.next(); // 本地 a.jpg → NAS c.jpg
    expect(service.current!.isNas, isTrue);
    expect(service.currentName, 'c.jpg');
  });

  test('fileFor 本地项直接返回同一 File，不经过缓存目录', () async {
    await writeLocal('a.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    final item = service.photos.single;

    expect(await service.fileFor(item), same(item.local));
    expect(service.cachedFileFor(item), same(item.local));
  });

  test('fileFor NAS 项：首次下载入缓存，再次命中不重复下载', () async {
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 3)],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 1 张');
    final item = service.photos.single;

    // cachedFileFor 是纯查询：不触发下载
    expect(service.cachedFileFor(item), isNull);
    expect(nas.downloadCount, 0);

    final first = await service.fileFor(item);
    expect(first, isNotNull);
    expect(nas.downloadCount, 1);
    expect(await first!.readAsBytes(), [1, 2, 3]);
    // 缓存文件名 = sha256(远程路径) 前 16 位 + 原扩展名
    final expectName =
        '${sha256.convert(utf8.encode('/photo/c.jpg')).toString().substring(0, 16)}.jpg';
    expect(p.basename(first.path), expectName);
    expect(p.dirname(first.path), cacheDir.path);

    final second = await service.fileFor(item);
    expect(nas.downloadCount, 1, reason: '缓存命中不得重复下载');
    expect(second!.path, first.path);
    expect(service.cachedFileFor(item)!.path, first.path);
  });

  test('fileForId 可在 NAS 全量列表完成前按索引路径直接下载', () async {
    final nas = FakeNasSource()..listGate = Completer<List<NasPhotoRef>>();
    final service = makeService();
    addTearDown(service.dispose);
    await service.applyNasConfig(nasConfig(), nas);

    final file = await service.fileForId('/photo/person-sample.jpg');

    expect(file, isNotNull);
    expect(await file!.readAsBytes(), [1, 2, 3]);
    expect(nas.downloadCount, 1);
  });

  test('缓存 LRU：超过上限时最久未访问的文件先被删', () async {
    // 预置一个 600B 的旧缓存文件
    final oldFile = File(p.join(cacheDir.path, 'old.jpg'));
    await oldFile.writeAsBytes(List.filled(600, 0x61));
    await oldFile.setLastModified(
      DateTime.now().subtract(const Duration(days: 1)),
    );

    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 600)],
      fileBytes: List.filled(600, 0x62),
    );
    final service = makeService(cacheLimitBytes: 1000);
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 1 张');

    final fetched = await service.fileFor(service.photos.single);
    expect(fetched, isNotNull);
    expect(await oldFile.exists(), isFalse, reason: '旧缓存应被 LRU 淘汰');
    expect(await fetched!.exists(), isTrue, reason: '新下载的文件应保留');
  });

  test('NAS listPhotos 抛错：本地列表仍在，nasStatus 为连接失败', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.jpg');
    final nas = FakeNasSource()..listThrows = true;
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '连接失败');

    expect(service.photos.map((i) => i.name), ['a.jpg', 'b.jpg']);
    expect(service.nasStatus, '连接失败');
  });

  test('nasEnabled=false：NAS 项不进列表，nasStatus 为未启用', () async {
    await writeLocal('a.jpg');
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 1)],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(enabled: false), nas);

    expect(service.photos.map((i) => i.name), ['a.jpg']);
    expect(service.nasStatus, '未启用');
    expect(nas.listCallCount, 0, reason: '未启用时不应访问 NAS');
  });

  test('forceEnabled 使展示节点在 NAS 配置关闭时仍拉取 HTTP 图源', () async {
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/compute/a.jpg', size: 1)],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();

    await service.applyNasConfig(
      nasConfig(enabled: false),
      nas,
      forceEnabled: true,
    );
    await pumpNasRefresh(service, nas, '已连接 1 张');

    expect(nas.listCallCount, 1);
    expect(service.photos.single.id, '/compute/a.jpg');
  });

  test('nasEnabled=true 但 remoteDir 为空：nasStatus 为未配置', () async {
    await writeLocal('a.jpg');
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 1)],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(remoteDir: ''), nas);

    expect(service.photos.map((i) => i.name), ['a.jpg']);
    expect(service.nasStatus, '未配置');
    expect(nas.listCallCount, 0, reason: '未配置时不应访问 NAS');
  });

  test('缓存目录未注入时 NAS 项不可 fileFor（返回 null 且不下载）', () async {
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 1)],
    );
    final service = PhotoService(photoDir.path); // 不给 cacheDir
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 1 张');

    expect(service.photos.single.isNas, isTrue);
    expect(await service.fileFor(service.photos.single), isNull);
    expect(service.cachedFileFor(service.photos.single), isNull);
    expect(nas.downloadCount, 0);
  });

  test('rescan 只扫本地目录：上传后出现新文件，当前张索引保持', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    service.next();
    expect(service.currentName, 'b.jpg');

    await writeLocal('c.jpg'); // 模拟手机上传
    await service.rescan();
    expect(service.photos.map((i) => i.name), ['a.jpg', 'b.jpg', 'c.jpg']);
    expect(service.currentName, 'b.jpg', reason: 'rescan 后当前张应保持不变');
  });

  test('next/prev 环绕；setDir 重置索引并扫描新目录', () async {
    await writeLocal('a.jpg');
    await writeLocal('b.jpg');
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();

    service.prev(); // 从 0 环绕到末尾
    expect(service.currentName, 'b.jpg');
    service.next(); // 环绕回 0
    expect(service.currentName, 'a.jpg');

    final newDir = await Directory.systemTemp.createTemp(
      'photo_service_setdir',
    );
    addTearDown(() => newDir.delete(recursive: true));
    await File(p.join(newDir.path, 'x.jpg')).writeAsBytes([9]);
    await service.setDir(newDir.path);
    expect(service.photos.map((i) => i.name), ['x.jpg']);
    expect(service.currentName, 'x.jpg');
  });

  test('prefetchNext 预下载下一张 NAS 图；下一张是本地则不下载', () async {
    final nas = FakeNasSource(
      refs: [
        NasPhotoRef(path: '/photo/c.jpg', size: 3),
        NasPhotoRef(path: '/photo/d.jpg', size: 3),
      ],
    );
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 2 张');

    // 当前 c.jpg（index 0），预取下一张 d.jpg
    service.prefetchNext();
    final dItem = service.photos[1];
    for (var i = 0; i < 100 && service.cachedFileFor(dItem) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.cachedFileFor(dItem), isNotNull, reason: '下一张 NAS 图应被预取');
    expect(nas.downloadCount, 1);

    // 切到 d.jpg 后加入一张本地图：当前张（d.jpg）保持，下一张环绕回
    // a.jpg（本地），prefetchNext 不应触发任何下载
    service.next();
    expect(service.currentName, 'd.jpg');
    await writeLocal('a.jpg');
    await service.rescan(); // [a.jpg(local), c.jpg, d.jpg]，当前仍是 d.jpg
    expect(service.currentName, 'd.jpg');
    service.prefetchNext();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(nas.downloadCount, 1, reason: '下一张为本地项时不应下载');
  });

  test('applyNasConfig 不阻塞在 NAS I/O 上：listPhotos 挂起也立即返回', () async {
    final nas = FakeNasSource()..listGate = Completer<List<NasPhotoRef>>();
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();

    var returned = false;
    final done = service
        .applyNasConfig(nasConfig(), nas)
        .then((_) => returned = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(returned, isTrue, reason: 'NAS 不可达时（连接超时 8 秒）启动与设置保存不得被阻塞');
    expect(nas.listCallCount, 1, reason: '刷新应已触发，只是不等待其完成');
    expect(service.nasStatus, '连接中');
    await done;

    // 后台刷新完成后状态照常更新
    nas.listGate!.complete([NasPhotoRef(path: '/photo/c.jpg', size: 1)]);
    await pumpNasRefresh(service, nas, '已连接 1 张');
  });

  test('NAS 下载中途失败：返回 null 且不残留部分缓存文件', () async {
    final nas = FakeNasSource(
      refs: [NasPhotoRef(path: '/photo/c.jpg', size: 3)],
    )..downloadThrowsPartial = true;
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 1 张');
    final item = service.photos.single;

    expect(await service.fileFor(item), isNull);
    // 缓存路径不得残留部分文件，否则 cachedFileFor 误命中、永久黑块
    final cachePath = p.join(
      cacheDir.path,
      '${sha256.convert(utf8.encode('/photo/c.jpg')).toString().substring(0, 16)}.jpg',
    );
    expect(await File(cachePath).exists(), isFalse, reason: '部分文件应被清理');
    expect(service.cachedFileFor(item), isNull);

    // 清理后重试不被污染：下载恢复后应能正常入缓存
    nas.downloadThrowsPartial = false;
    expect(await service.fileFor(item), isNotNull);
  });

  test('NAS 状态含被过滤数量：已连接 N 张（已过滤 M）', () async {
    final nas = FakeNasSource(
      refs: [
        NasPhotoRef(path: '/photo/a.jpg', size: 1),
        NasPhotoRef(path: '/photo/b.jpg', size: 1),
        NasPhotoRef(path: '/photo/c.jpg', size: 1),
      ],
    )..filteredCount = 1; // 模拟真实源：1 张截图被过滤规则排除
    final service = makeService();
    addTearDown(service.dispose);
    await service.rescan();
    await service.applyNasConfig(nasConfig(), nas);
    await pumpNasRefresh(service, nas, '已连接 3 张（已过滤 1）');
    expect(service.nasStatus, '已连接 3 张（已过滤 1）');

    // M=0 时不带括号（默认 filteredCount=0，「混合列表」用例已断言 '已连接 2 张'）
  });
}
