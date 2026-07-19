import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:smart_frame/config/app_config.dart';
import 'package:smart_frame/services/photo_index_service.dart';
import 'package:smart_frame/services/photo_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// F 阶段后 PhotoIndexService 只读守护进程库。测试：预建 SQLite（守护进程
/// schema + 行）→ PhotoIndexService.init 读 → setHidden / 筛选。
void main() {
  late Directory photoDir;
  late Directory cacheDir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    photoDir = await Directory.systemTemp.createTemp('pix_photos');
    cacheDir = await Directory.systemTemp.createTemp('pix_cache');
  });

  tearDown(() async {
    if (await photoDir.exists()) await photoDir.delete(recursive: true);
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });

  /// 建一份守护进程风格的库，photos/faces 插指定行。
  Future<String> seedDb(Map<String, Map<String, Object?>> photosRows,
      List<Map<String, Object?>> facesRows) async {
    final dbPath = p.join(cacheDir.path, 'idx.db');
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    await db.execute('''
      CREATE TABLE photos (
        id TEXT PRIMARY KEY, sha256 TEXT, phash INTEGER,
        is_photo INTEGER, tags TEXT, tagged_at INTEGER,
        hidden INTEGER DEFAULT 0, reason TEXT, indexed_at INTEGER,
        embedding_dinov2 BLOB, embedding_clip BLOB, embedding_dim INTEGER,
        quality_score REAL, width INTEGER, height INTEGER, taken_at INTEGER, thumb_path TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE faces (
        id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id TEXT, subject_name TEXT,
        face_embedding BLOB, bbox TEXT
      )
    ''');
    for (final r in photosRows.values) {
      await db.insert('photos', r, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final r in facesRows) {
      await db.insert('faces', r);
    }
    await db.close();
    return dbPath;
  }

  test('init 读库 hidden → setHidden，indexStatus 反映统计', () async {
    final aId = p.join(photoDir.path, 'a.jpg');
    final bId = p.join(photoDir.path, 'b.jpg');
    await File(aId).writeAsBytes([1]);
    await File(bId).writeAsBytes([2]);
    final photos = PhotoService(photoDir.path, cacheDir: cacheDir.path);
    addTearDown(photos.dispose);
    await photos.rescan();

    final dbPath = await seedDb({
      'a': {'id': aId, 'hidden': 1, 'reason': 'not_photo', 'tags': '截图'},
      'b': {'id': bId, 'hidden': 0, 'reason': null, 'tags': '风景,户外'},
    }, []);

    final index = PhotoIndexService(photos, SqliteIndexBackend(dbPath));
    addTearDown(index.dispose);
    await index.init(AppConfig());

    expect(photos.hiddenCount, 1);            // a 被 hidden
    expect(photos.playable.length, 1);        // 只剩 b
    expect(photos.current!.id, bId);          // 当前跳到 b
    expect(index.indexStatus, contains('已索引 2'));
    expect(index.indexStatus, contains('隐藏 1'));
  });

  test('byTag 筛选返回匹配 id', () async {
    final aId = p.join(photoDir.path, 'a.jpg');
    final bId = p.join(photoDir.path, 'b.jpg');
    await File(aId).writeAsBytes([1]);
    await File(bId).writeAsBytes([2]);
    final photos = PhotoService(photoDir.path, cacheDir: cacheDir.path);
    addTearDown(photos.dispose);
    await photos.rescan();

    final dbPath = await seedDb({
      'a': {'id': aId, 'hidden': 0, 'tags': '猫,宠物'},
      'b': {'id': bId, 'hidden': 0, 'tags': '风景,户外'},
    }, []);

    final index = PhotoIndexService(photos, SqliteIndexBackend(dbPath));
    addTearDown(index.dispose);
    await index.init(AppConfig());

    expect(await index.byTag('猫'), {aId});
    expect(await index.byTag('户外'), {bId});
    expect(await index.byTag('不存在'), isEmpty);
  });

  test('byPerson / persons 读 faces 表', () async {
    final aId = p.join(photoDir.path, 'a.jpg');
    final bId = p.join(photoDir.path, 'b.jpg');
    await File(aId).writeAsBytes([1]);
    await File(bId).writeAsBytes([2]);
    final photos = PhotoService(photoDir.path, cacheDir: cacheDir.path);
    addTearDown(photos.dispose);
    await photos.rescan();

    final dbPath = await seedDb({
      'a': {'id': aId, 'hidden': 0, 'tags': null},
      'b': {'id': bId, 'hidden': 0, 'tags': null},
    }, [
      {'photo_id': aId, 'subject_name': 'person_0', 'bbox': '[0,0,1,1]'},
      {'photo_id': bId, 'subject_name': 'person_0', 'bbox': '[0,0,1,1]'},
      {'photo_id': bId, 'subject_name': 'person_1', 'bbox': '[0,0,1,1]'},
    ]);

    final index = PhotoIndexService(photos, SqliteIndexBackend(dbPath));
    addTearDown(index.dispose);
    await index.init(AppConfig());

    expect(await index.persons(), ['person_0', 'person_1']);
    expect(await index.byPerson('person_0'), {aId, bId});
    expect(await index.byPerson('person_1'), {bId});
  });
}
