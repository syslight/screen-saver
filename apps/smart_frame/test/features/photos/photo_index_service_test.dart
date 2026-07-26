import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:smart_frame/core/config/app_config.dart';
import 'package:smart_frame/features/photos/application/photo_index_service.dart';
import 'package:smart_frame/features/photos/application/photo_service.dart';
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
  Future<String> seedDb(
    Map<String, Map<String, Object?>> photosRows,
    List<Map<String, Object?>> facesRows, [
    List<Map<String, Object?>> profileRows = const [],
  ]) async {
    final dbPath = p.join(cacheDir.path, 'idx.db');
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    await db.execute('''
      CREATE TABLE photos (
        id TEXT PRIMARY KEY, sha256 TEXT, phash INTEGER,
        is_photo INTEGER, tags TEXT, tagged_at INTEGER,
        hidden INTEGER DEFAULT 0, reason TEXT, indexed_at INTEGER,
        embedding_dinov2 BLOB, embedding_clip BLOB, embedding_dim INTEGER,
        quality_score REAL, width INTEGER, height INTEGER, taken_at INTEGER,
        thumb_path TEXT, caption TEXT, location_name TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE faces (
        id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id TEXT, subject_name TEXT,
        face_embedding BLOB, bbox TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE person_profiles (
        subject_name TEXT PRIMARY KEY, identity_label TEXT NOT NULL,
        confirmed INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 100, updated_at INTEGER
      )
    ''');
    for (final r in photosRows.values) {
      await db.insert(
        'photos',
        r,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final r in facesRows) {
      await db.insert('faces', r);
    }
    for (final r in profileRows) {
      await db.insert('person_profiles', r);
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

    expect(photos.hiddenCount, 1); // a 被 hidden
    expect(photos.playable.length, 1); // 只剩 b
    expect(photos.current!.id, bId); // 当前跳到 b
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

    final dbPath = await seedDb(
      {
        'a': {'id': aId, 'hidden': 0, 'tags': null},
        'b': {'id': bId, 'hidden': 0, 'tags': null},
      },
      [
        {'photo_id': aId, 'subject_name': 'person_0', 'bbox': '[0,0,1,1]'},
        {'photo_id': bId, 'subject_name': 'person_0', 'bbox': '[0,0,1,1]'},
        {'photo_id': bId, 'subject_name': 'person_1', 'bbox': '[0,0,1,1]'},
      ],
    );

    final index = PhotoIndexService(photos, SqliteIndexBackend(dbPath));
    addTearDown(index.dispose);
    await index.init(AppConfig());

    expect(await index.persons(), ['person_0', 'person_1']);
    expect(await index.byPerson('person_0'), {aId, bId});
    expect(await index.byPerson('person_1'), {bId});
  });

  test('照片路径推断拍摄时间与明确地点目录', () {
    final precise = inferPhotoDate(
      '/Photos/DCIM/Camera/2022/10/IMG_20221001_105505.jpg',
    );
    expect(precise?.$1, DateTime(2022, 10, 1, 10, 55, 5));
    expect(precise?.$2, 'second');

    final month = inferPhotoDate('/Photos/iPhone/2021/10/IMG_3080.HEIC');
    expect(month?.$1, DateTime(2021, 10, 1));
    expect(month?.$2, 'month');

    final chineseMonth = inferPhotoDate('/Photos/2013年05月/IMG_3080.JPG');
    expect(chineseMonth?.$1, DateTime(2013, 5, 1));
    expect(chineseMonth?.$2, 'month');

    expect(inferPhotoLocation('/Photos/OneDrive/图片/阳朔-hh/IMG_7957.JPG'), '阳朔');
    expect(
      inferPhotoLocation('/Photos/Xiaomi 12S Ultra/DCIM/Camera/2022/10/a.jpg'),
      isNull,
    );
    expect(inferPhotoLocation('/Photos/2013年05月/IMG_3080.JPG'), isNull);
    expect(inferPhotoLocation('/home/peidong/Pictures/IMG_3080.JPG'), isNull);
    expect(inferPhotoLocation('/Photos/孩子生日/IMG_3080.JPG'), isNull);
  });

  test('describe 读取时间、地点并把旧 tags 转成文字解说', () async {
    final id = p.join(photoDir.path, 'a.jpg');
    await File(id).writeAsBytes([1]);
    final dbPath = await seedDb({
      'a': {
        'id': id,
        'hidden': 0,
        'tags': '儿童,户外',
        'taken_at': DateTime(2020, 5, 2, 9, 30).millisecondsSinceEpoch,
      },
    }, []);
    final backend = SqliteIndexBackend(dbPath);
    addTearDown(backend.close);
    await backend.open();
    final description = await backend.describe(id);

    expect(description?.takenAt, DateTime(2020, 5, 2, 9, 30));
    expect(description?.caption, '家人在户外中留下了这一刻。');
  });

  test('describe 只显示家长确认的家庭身份', () async {
    final id = p.join(photoDir.path, 'family.jpg');
    await File(id).writeAsBytes([1]);
    final dbPath = await seedDb(
      {
        'family': {'id': id, 'hidden': 0, 'caption': '他们正在客厅一起看书。'},
      },
      [
        {'photo_id': id, 'subject_name': 'person_0', 'bbox': '[0,0,1,1]'},
        {'photo_id': id, 'subject_name': 'person_1', 'bbox': '[0,0,1,1]'},
        {'photo_id': id, 'subject_name': 'person_2', 'bbox': '[0,0,1,1]'},
      ],
      [
        {
          'subject_name': 'person_0',
          'identity_label': '爷爷',
          'confirmed': 1,
          'sort_order': 10,
        },
        {
          'subject_name': 'person_1',
          'identity_label': '弟弟',
          'confirmed': 1,
          'sort_order': 20,
        },
        {
          'subject_name': 'person_2',
          'identity_label': '访客',
          'confirmed': 0,
          'sort_order': 30,
        },
      ],
    );
    final backend = SqliteIndexBackend(dbPath);
    addTearDown(backend.close);
    await backend.open();

    final description = await backend.describe(id);

    expect(description?.identities, ['爷爷', '弟弟']);
    expect(description?.caption, '他们正在客厅一起看书。');
    expect(PhotoDescription.fromJson(description!.toJson()).identities, [
      '爷爷',
      '弟弟',
    ]);
  });
}
