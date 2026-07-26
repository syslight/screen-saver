import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/app_config.dart';
import 'photo_service.dart';

/// 当前照片的说明信息。索引库字段优先，路径/文件时间只作安全回退。
class PhotoDescription {
  const PhotoDescription({
    required this.photoId,
    this.takenAt,
    this.datePrecision = 'second',
    this.timeIsFileModified = false,
    this.location,
    this.caption,
    this.identities = const [],
  });

  final String photoId;
  final DateTime? takenAt;

  /// second / day / month / year，避免把只有年月的目录误显示成某月 1 日。
  final String datePrecision;
  final bool timeIsFileModified;
  final String? location;
  final String? caption;

  /// 家长确认的家庭身份（如“爷爷”“弟弟”），不包含姓名。
  final List<String> identities;

  bool get isEmpty =>
      takenAt == null &&
      location == null &&
      caption == null &&
      identities.isEmpty;

  String? get dateText {
    final d = takenAt?.toLocal();
    if (d == null) return null;
    String two(int value) => value.toString().padLeft(2, '0');
    final prefix = timeIsFileModified ? '文件时间 ' : '';
    return switch (datePrecision) {
      'year' => '$prefix${d.year}年',
      'month' => '$prefix${d.year}年${d.month}月',
      'day' => '$prefix${d.year}年${d.month}月${d.day}日',
      _ =>
        '$prefix${d.year}年${d.month}月${d.day}日 '
            '${two(d.hour)}:${two(d.minute)}',
    };
  }

  PhotoDescription merge(PhotoDescription? preferred) {
    if (preferred == null) return this;
    return PhotoDescription(
      photoId: photoId,
      takenAt: preferred.takenAt ?? takenAt,
      datePrecision: preferred.takenAt != null
          ? preferred.datePrecision
          : datePrecision,
      timeIsFileModified: preferred.takenAt != null
          ? preferred.timeIsFileModified
          : timeIsFileModified,
      location: _clean(preferred.location) ?? location,
      caption: _clean(preferred.caption) ?? caption,
      identities: preferred.identities.isNotEmpty
          ? preferred.identities
          : identities,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': photoId,
    'takenAt': takenAt?.millisecondsSinceEpoch,
    'datePrecision': datePrecision,
    'timeIsFileModified': timeIsFileModified,
    'location': location,
    'caption': caption,
    'identities': identities,
  };

  factory PhotoDescription.fromJson(Map<String, dynamic> json) {
    final millis = json['takenAt'] as int?;
    return PhotoDescription(
      photoId: json['id'] as String? ?? '',
      takenAt: millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
      datePrecision: json['datePrecision'] as String? ?? 'second',
      timeIsFileModified: json['timeIsFileModified'] as bool? ?? false,
      location: _clean(json['location'] as String?),
      caption: _clean(json['caption'] as String?),
      identities:
          (json['identities'] as List?)?.whereType<String>().toList() ??
          const [],
    );
  }

  factory PhotoDescription.infer(PhotoItem item) {
    final inferred = inferPhotoDate(item.id);
    final fallbackTime = inferred?.$1 ?? item.modifiedAt;
    return PhotoDescription(
      photoId: item.id,
      takenAt: fallbackTime,
      datePrecision: inferred?.$2 ?? 'day',
      timeIsFileModified: inferred == null && item.modifiedAt != null,
      location: inferPhotoLocation(item.id),
    );
  }

  static String? _clean(String? value) {
    final cleaned = value?.trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }
}

/// 从常见相机文件名和照片目录解析时间，返回 (时间, 精度)。
(DateTime, String)? inferPhotoDate(String path) {
  final compact = RegExp(
    r'(19|20)(\d{2})[-_]?(\d{2})[-_]?(\d{2})'
    r'(?:[T _-]?(\d{2})[:_-]?(\d{2})[:_-]?(\d{2}))?',
  ).allMatches(path).toList();
  if (compact.isNotEmpty) {
    final match = compact.last;
    final year = int.parse('${match.group(1)}${match.group(2)}');
    final month = int.parse(match.group(3)!);
    final day = int.parse(match.group(4)!);
    final hasTime = match.group(5) != null;
    final parsed = _safeDate(
      year,
      month,
      day,
      hasTime ? int.parse(match.group(5)!) : 0,
      hasTime ? int.parse(match.group(6)!) : 0,
      hasTime ? int.parse(match.group(7)!) : 0,
    );
    if (parsed != null) return (parsed, hasTime ? 'second' : 'day');
  }

  final chineseDate = RegExp(
    r'(19|20)(\d{2})年(\d{1,2})月(?:(\d{1,2})日)?',
  ).allMatches(path).toList();
  if (chineseDate.isNotEmpty) {
    final match = chineseDate.last;
    final year = int.parse('${match.group(1)}${match.group(2)}');
    final month = int.parse(match.group(3)!);
    final dayText = match.group(4);
    final parsed = _safeDate(year, month, int.tryParse(dayText ?? '') ?? 1);
    if (parsed != null) return (parsed, dayText == null ? 'month' : 'day');
  }

  final segments = path.split(RegExp(r'[/\\]+'));
  for (var i = segments.length - 2; i >= 1; i--) {
    final month = int.tryParse(segments[i]);
    final year = int.tryParse(segments[i - 1]);
    if (year != null && month != null && year >= 1900 && month <= 12) {
      final parsed = _safeDate(year, month, 1);
      if (parsed != null) return (parsed, 'month');
    }
  }
  return null;
}

DateTime? _safeDate(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  try {
    final value = DateTime(year, month, day, hour, minute, second);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  } catch (_) {
    return null;
  }
}

/// 仅把明确的自定义相册目录当作地点；设备名、备份目录、日期目录均排除。
String? inferPhotoLocation(String path) {
  final segments = path.split(RegExp(r'[/\\]+'));
  if (segments.length < 2) return null;
  for (var i = segments.length - 2; i >= 0; i--) {
    var value = segments[i];
    if (value.contains('%')) {
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {}
    }
    value = value.trim();
    if (value.isEmpty || _genericPhotoFolders.contains(value.toLowerCase())) {
      continue;
    }
    if (RegExp(r'^\d{1,4}([_-]\d{1,2}){0,2}$').hasMatch(value)) continue;
    if (RegExp(r'^\d{4}年(?:\d{1,2}月)?(?:\d{1,2}日)?$').hasMatch(value)) {
      continue;
    }
    if (RegExp(
      r'(iphone|ipad|xiaomi|redmi|huawei|honor|oppo|vivo|pixel|desktop|android|lio-|mi\d|备份)',
      caseSensitive: false,
    ).hasMatch(value)) {
      continue;
    }
    value = value.replaceFirst(RegExp(r'[-_ ](?:hh|照片|相册)$'), '');
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(value)) continue;
    final knownPlace = RegExp(
      r'(北京|上海|广州|深圳|杭州|成都|重庆|西安|武汉|南京|苏州|阳朔|桂林|三亚|厦门|香港|澳门|台湾|日本|美国|欧洲)',
    ).hasMatch(value);
    final placeSuffix = RegExp(
      r'(省|市|县|区|镇|乡|村|路|街|公园|广场|山|湖|海|湾|岛|机场|车站|酒店|餐厅|学校|医院|博物馆|科技馆|动物园|植物园|寺|宫)$',
    ).hasMatch(value);
    if ((knownPlace || placeSuffix) && value.length <= 24) return value;
  }
  return null;
}

const _genericPhotoFolders = {
  'homes',
  'home',
  'syslight',
  'photos',
  'photo',
  'pictures',
  '圖片',
  '图片',
  'mobilebackup',
  'moments',
  'mobile',
  'dcim',
  'camera',
  'onedrive',
  '自定义备份',
  '.piccache',
  'xiaomi',
  'peidong',
  'orangepi',
  '共享',
  '下载',
  '相册',
  '照片',
  '收藏',
};

/// 照片索引后端抽象：计算节点用 SQLite，展示节点用 HTTP（C/S 分离）。
abstract class PhotoIndexBackend {
  Future<void> open();
  Future<Map<String, int>> status(); // {total, hidden, tagged, persons}
  Future<Set<String>> hidden();
  Future<Set<String>> byTag(String tag);
  Future<Set<String>> byPerson(String person);
  Future<List<String>> persons();
  Future<PhotoDescription?> describe(String id);
  Future<void> markHidden(String id, String reason);
  Future<Set<String>> searchText(String query);
  void close();
}

/// 计算节点：直接读守护进程写的共享 SQLite。
class SqliteIndexBackend implements PhotoIndexBackend {
  SqliteIndexBackend(this.dbPath);
  final String dbPath;
  Database? _db;

  @override
  Future<void> open() async {
    sqfliteFfiInit();
    _db = await databaseFactoryFfi.openDatabase(dbPath);
    await _db!.execute('PRAGMA busy_timeout=10000');
    await _ensureSchema(_db!);
  }

  Future<int> _count(String from, {String? distinct}) async {
    final sel = distinct == null ? 'COUNT(*)' : 'COUNT(DISTINCT $distinct)';
    final rows = await _db!.rawQuery('SELECT $sel AS c FROM $from');
    return rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0);
  }

  @override
  Future<Map<String, int>> status() async {
    final total = await _count('photos');
    final hidden = await _count('photos WHERE hidden=1');
    final tagged = await _count('photos WHERE tags IS NOT NULL');
    final persons = await _count(
      'faces WHERE subject_name IS NOT NULL',
      distinct: 'subject_name',
    );
    return {
      'total': total,
      'hidden': hidden,
      'tagged': tagged,
      'persons': persons,
    };
  }

  @override
  Future<Set<String>> hidden() async {
    final rows = await _db!.rawQuery('SELECT id FROM photos WHERE hidden=1');
    return rows.map((r) => r['id'] as String).toSet();
  }

  @override
  Future<Set<String>> byTag(String tag) async {
    final rows = await _db!.rawQuery(
      'SELECT id FROM photos WHERE tags LIKE ?',
      ['%$tag%'],
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  @override
  Future<Set<String>> byPerson(String person) async {
    final rows = await _db!.rawQuery(
      'SELECT DISTINCT photo_id FROM faces WHERE subject_name=?',
      [person],
    );
    return rows.map((r) => r['photo_id'] as String).toSet();
  }

  @override
  Future<List<String>> persons() async {
    final rows = await _db!.rawQuery(
      'SELECT DISTINCT subject_name FROM faces WHERE subject_name IS NOT NULL '
      'ORDER BY subject_name',
    );
    return rows.map((r) => r['subject_name'] as String).toList();
  }

  @override
  Future<PhotoDescription?> describe(String id) async {
    final rows = await _db!.rawQuery(
      'SELECT taken_at, tags, caption, location_name FROM photos WHERE id=?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final tags = (row['tags'] as String?)?.trim();
    final storedCaption = (row['caption'] as String?)?.trim();
    final caption = storedCaption != null && storedCaption.isNotEmpty
        ? storedCaption
        : _captionFromTags(tags);
    final identityRows = await _db!.rawQuery(
      'SELECT DISTINCT p.identity_label FROM faces f '
      'JOIN person_profiles p ON p.subject_name=f.subject_name '
      'WHERE f.photo_id=? AND p.confirmed=1 '
      'ORDER BY p.sort_order, p.identity_label',
      [id],
    );
    final millis = row['taken_at'] as int?;
    return PhotoDescription(
      photoId: id,
      takenAt: millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
      datePrecision: 'second',
      location: row['location_name'] as String?,
      caption: caption,
      identities: identityRows
          .map((row) => row['identity_label'] as String)
          .toList(),
    );
  }

  @override
  Future<void> markHidden(String id, String reason) async {
    await _db!.execute('UPDATE photos SET hidden=1, reason=? WHERE id=?', [
      reason,
      id,
    ]);
  }

  @override
  Future<Set<String>> searchText(String query) async {
    // compute 节点：调自己的 control_server（代理 daemon search_server）
    final resp = await http.get(
      Uri.parse(
        'http://localhost:8780/api/search/text?q=${Uri.encodeQueryComponent(query)}&n=500',
      ),
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['results'] as List).map((e) => e['id'] as String).toSet();
  }

  Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS photos (
        id TEXT PRIMARY KEY, sha256 TEXT, phash INTEGER,
        is_photo INTEGER, tags TEXT, tagged_at INTEGER,
        hidden INTEGER DEFAULT 0, reason TEXT, indexed_at INTEGER,
        embedding_dinov2 BLOB, embedding_clip BLOB, embedding_dim INTEGER,
        quality_score REAL, width INTEGER, height INTEGER, taken_at INTEGER, thumb_path TEXT
      )
    ''');
    final columns = {
      for (final row in await db.rawQuery('PRAGMA table_info(photos)'))
        row['name'] as String,
    };
    if (!columns.contains('caption')) {
      await _addColumnWithRetry(db, 'caption', 'TEXT');
    }
    if (!columns.contains('location_name')) {
      await _addColumnWithRetry(db, 'location_name', 'TEXT');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS faces (
        id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id TEXT, subject_name TEXT,
        face_embedding BLOB, bbox TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS person_profiles (
        subject_name TEXT PRIMARY KEY,
        identity_label TEXT NOT NULL,
        confirmed INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 100,
        updated_at INTEGER
      )
    ''');
  }

  Future<void> _addColumnWithRetry(
    Database db,
    String column,
    String type,
  ) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await db.execute('ALTER TABLE photos ADD COLUMN $column $type');
        return;
      } catch (error) {
        final message = error.toString().toLowerCase();
        if (message.contains('duplicate column')) return;
        if (!message.contains('locked') || attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @override
  void close() => _db?.close();
}

String? _captionFromTags(String? rawTags) {
  final tags = rawTags
      ?.split(RegExp(r'[,，]'))
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .take(3)
      .toList();
  if (tags == null || tags.isEmpty) return null;
  const peopleTags = {
    '人物',
    '家庭',
    '家人',
    '合影',
    '亲子',
    '儿童',
    '婴儿',
    '男孩',
    '女孩',
    '男人',
    '女人',
    '老人',
    '老年人',
    '老年妇女',
  };
  final hasPeople = tags.any(peopleTags.contains);
  final scene = tags.where((tag) => !peopleTags.contains(tag)).toList();
  if (hasPeople) {
    return scene.isEmpty ? '家人留下了这个值得回看的瞬间。' : '家人在${scene.join('、')}中留下了这一刻。';
  }
  return '照片呈现了${tags.join('、')}。';
}

/// 展示节点：HTTP 调计算节点 control_server 的 /api/index/*。
class HttpIndexBackend implements PhotoIndexBackend {
  HttpIndexBackend(this.baseUrl);
  final String baseUrl;

  @override
  Future<void> open() async {}

  @override
  Future<Map<String, int>> status() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/index/status'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return {
      'total': body['total'] as int? ?? 0,
      'hidden': body['hidden'] as int? ?? 0,
      'tagged': body['tagged'] as int? ?? 0,
      'persons': body['persons'] as int? ?? 0,
    };
  }

  @override
  Future<Set<String>> hidden() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/index/hidden'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['hidden'] as List).cast<String>().toSet();
  }

  @override
  Future<Set<String>> byTag(String tag) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/index/bytag?t=${Uri.encodeQueryComponent(tag)}'),
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['ids'] as List).cast<String>().toSet();
  }

  @override
  Future<Set<String>> byPerson(String person) async {
    final resp = await http.get(
      Uri.parse(
        '$baseUrl/api/index/byperson?p=${Uri.encodeQueryComponent(person)}',
      ),
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['ids'] as List).cast<String>().toSet();
  }

  @override
  Future<List<String>> persons() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/index/persons'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['persons'] as List).cast<String>().toList();
  }

  @override
  Future<PhotoDescription?> describe(String id) async {
    final resp = await http.get(
      Uri.parse(
        '$baseUrl/api/index/description?id=${Uri.encodeQueryComponent(id)}',
      ),
    );
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw StateError('照片说明读取失败：${resp.statusCode}');
    }
    return PhotoDescription.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> markHidden(String id, String reason) async {
    await http.post(
      Uri.parse('$baseUrl/api/annotate'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'id': id, 'reason': reason}),
    );
  }

  @override
  Future<Set<String>> searchText(String query) async {
    final resp = await http.get(
      Uri.parse(
        '$baseUrl/api/search/text?q=${Uri.encodeQueryComponent(query)}&n=500',
      ),
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['results'] as List).map((e) => e['id'] as String).toSet();
  }

  @override
  void close() {}
}

/// 照片索引服务：持有 [backend]，把 hidden 同步到 [PhotoService]（播放跳过），
/// 暴露按标签/人物筛选。计算/展示节点共用，仅 backend 不同。
class PhotoIndexService extends ChangeNotifier {
  PhotoIndexService(this._photos, this.backend) {
    _photos.addListener(_handlePhotosChanged);
  }

  final PhotoService _photos;
  final PhotoIndexBackend backend;

  Timer? _poll;
  bool _dedupEnabled = true;
  Set<String> _lastHidden = {};
  Map<String, int> _status = {};
  bool _ready = false;
  String? _descriptionId;
  int _descriptionSeq = 0;
  PhotoDescription? _currentDescription;

  String get indexStatus {
    final t = _status['total'] ?? 0;
    if (t == 0) return '守护进程待运行（库空）';
    final h = _status['hidden'] ?? 0;
    final tagged = _status['tagged'] ?? 0;
    final persons = _status['persons'] ?? 0;
    return '已索引 $t（隐藏 $h / 已标签 $tagged / 人物 $persons）';
  }

  Set<String> get hiddenIds => Set.unmodifiable(_lastHidden);
  Map<String, int> get statusMap => Map.unmodifiable(_status);
  PhotoDescription? get currentDescription => _currentDescription;

  Future<void> init(AppConfig config) async {
    _dedupEnabled = config.dedupEnabled;
    await backend.open();
    _ready = true;
    await _refresh();
    _onPhotosChanged(force: true);
    _poll?.cancel();
    _poll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refresh()),
    );
  }

  void applyConfig(AppConfig config) {
    final enabled = config.dedupEnabled;
    if (_dedupEnabled != enabled) {
      _dedupEnabled = enabled;
      if (!enabled) {
        _photos.clearHidden();
        notifyListeners();
      } else {
        unawaited(_refresh());
      }
    }
  }

  Future<void> _refresh() async {
    try {
      _status = await backend.status();
      final hidden = await backend.hidden();
      if (_dedupEnabled && !_setEq(hidden, _lastHidden)) {
        _lastHidden = hidden;
        _photos.setHidden(hidden);
      }
      notifyListeners();
    } catch (e) {
      _status = {};
    }
  }

  void _onPhotosChanged({bool force = false}) {
    final item = _photos.current;
    final id = item?.id;
    if (!force && id == _descriptionId) return;
    _descriptionId = id;
    final seq = ++_descriptionSeq;
    _currentDescription = item == null ? null : PhotoDescription.infer(item);
    notifyListeners();
    if (!_ready || item == null) return;
    unawaited(_loadDescription(item, seq));
  }

  void _handlePhotosChanged() => _onPhotosChanged();

  Future<void> _loadDescription(PhotoItem item, int seq) async {
    try {
      final indexed = await backend.describe(item.id);
      if (seq != _descriptionSeq || _descriptionId != item.id) return;
      _currentDescription = PhotoDescription.infer(item).merge(indexed);
      notifyListeners();
    } catch (_) {
      // 索引暂不可用时继续显示路径/文件时间推断，不影响轮播。
    }
  }

  Future<Set<String>> byTag(String tag) => backend.byTag(tag);
  Future<Set<String>> byPerson(String person) => backend.byPerson(person);
  Future<List<String>> persons() => backend.persons();
  Future<Set<String>> searchText(String query) => backend.searchText(query);

  /// 人工标注：标记照片为某类别并立即隐藏（playable 跳过）。存 reason=`user_<类别>`。
  /// 守护进程并发写同一 SQLite 会 locked，PRAGMA busy_timeout 在 sqflite_ffi 不透传，
  /// 故在此重试（5 次 × 500ms，daemon 短事务重试必中）。
  Future<void> annotate(String id, String reason) async {
    for (var i = 0; i < 10; i++) {
      try {
        await backend.markHidden(id, 'user_$reason');
        break;
      } catch (e) {
        if (i < 4 && e.toString().contains('locked')) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        rethrow;
      }
    }
    _lastHidden = {..._lastHidden, id};
    _photos.setHidden([id]);
    notifyListeners();
  }

  bool _setEq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  void dispose() {
    _poll?.cancel();
    _photos.removeListener(_handlePhotosChanged);
    backend.close();
    super.dispose();
  }
}
