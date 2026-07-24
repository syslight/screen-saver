import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/app_config.dart';
import 'photo_service.dart';

/// 照片索引后端抽象：计算节点用 SQLite，展示节点用 HTTP（C/S 分离）。
abstract class PhotoIndexBackend {
  Future<void> open();
  Future<Map<String, int>> status(); // {total, hidden, tagged, persons}
  Future<Set<String>> hidden();
  Future<Set<String>> byTag(String tag);
  Future<Set<String>> byPerson(String person);
  Future<List<String>> persons();
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
    await _db!.execute('PRAGMA busy_timeout=5000'); // 等 5s 避免与守护进程写冲突
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
    final persons =
        await _count('faces WHERE subject_name IS NOT NULL', distinct: 'subject_name');
    return {'total': total, 'hidden': hidden, 'tagged': tagged, 'persons': persons};
  }

  @override
  Future<Set<String>> hidden() async {
    final rows = await _db!.rawQuery('SELECT id FROM photos WHERE hidden=1');
    return rows.map((r) => r['id'] as String).toSet();
  }

  @override
  Future<Set<String>> byTag(String tag) async {
    final rows =
        await _db!.rawQuery('SELECT id FROM photos WHERE tags LIKE ?', ['%$tag%']);
    return rows.map((r) => r['id'] as String).toSet();
  }

  @override
  Future<Set<String>> byPerson(String person) async {
    final rows = await _db!.rawQuery(
        'SELECT DISTINCT photo_id FROM faces WHERE subject_name=?', [person]);
    return rows.map((r) => r['photo_id'] as String).toSet();
  }

  @override
  Future<List<String>> persons() async {
    final rows = await _db!.rawQuery(
        'SELECT DISTINCT subject_name FROM faces WHERE subject_name IS NOT NULL '
        'ORDER BY subject_name');
    return rows.map((r) => r['subject_name'] as String).toList();
  }

  @override
  Future<void> markHidden(String id, String reason) async {
    await _db!
        .execute('UPDATE photos SET hidden=1, reason=? WHERE id=?', [reason, id]);
  }

  @override
  Future<Set<String>> searchText(String query) async {
    // compute 节点：调自己的 control_server（代理 daemon search_server）
    final resp = await http.get(Uri.parse(
        'http://localhost:8780/api/search/text?q=${Uri.encodeQueryComponent(query)}&n=500'));
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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS faces (
        id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id TEXT, subject_name TEXT,
        face_embedding BLOB, bbox TEXT
      )
    ''');
  }

  @override
  void close() => _db?.close();
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
    final resp = await http
        .get(Uri.parse('$baseUrl/api/index/bytag?t=${Uri.encodeQueryComponent(tag)}'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['ids'] as List).cast<String>().toSet();
  }

  @override
  Future<Set<String>> byPerson(String person) async {
    final resp = await http.get(Uri.parse(
        '$baseUrl/api/index/byperson?p=${Uri.encodeQueryComponent(person)}'));
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
  Future<void> markHidden(String id, String reason) async {
    await http.post(Uri.parse('$baseUrl/api/annotate'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'id': id, 'reason': reason}));
  }

  @override
  Future<Set<String>> searchText(String query) async {
    final resp = await http.get(Uri.parse(
        '$baseUrl/api/search/text?q=${Uri.encodeQueryComponent(query)}&n=500'));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['results'] as List).map((e) => e['id'] as String).toSet();
  }

  @override
  void close() {}
}

/// 照片索引服务：持有 [backend]，把 hidden 同步到 [PhotoService]（播放跳过），
/// 暴露按标签/人物筛选。计算/展示节点共用，仅 backend 不同。
class PhotoIndexService extends ChangeNotifier {
  PhotoIndexService(this._photos, this.backend);

  final PhotoService _photos;
  final PhotoIndexBackend backend;

  Timer? _poll;
  bool _dedupEnabled = true;
  Set<String> _lastHidden = {};
  Map<String, int> _status = {};

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

  Future<void> init(AppConfig config) async {
    _dedupEnabled = config.dedupEnabled;
    await backend.open();
    await _refresh();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_refresh()));
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
    backend.close();
    super.dispose();
  }
}
