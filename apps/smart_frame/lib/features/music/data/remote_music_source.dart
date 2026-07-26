import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:smart_frame/features/music/domain/music_models.dart';
import 'package:smart_frame/features/photos/application/photo_index_service.dart';

class RemoteMusicSource {
  RemoteMusicSource({
    required this.baseUrl,
    required this.nodeId,
    required this.deviceKey,
    required this.cacheDir,
  });

  final String baseUrl;
  final String nodeId;
  final String deviceKey;
  final String cacheDir;

  Map<String, String> get _headers => {
    'Authorization': 'Node $nodeId:$deviceKey',
  };

  Future<MusicTrack?> select(
    PhotoDescription? description,
    MusicMood mood,
  ) async {
    final query = <String, String>{'mood': mood.name};
    final photoId = description?.photoId;
    if (photoId != null && photoId.isNotEmpty) query['photoId'] = photoId;
    final uri = Uri.parse(
      '$baseUrl/api/v1/media/music/select',
    ).replace(queryParameters: query);
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode == 204) return null;
    if (response.statusCode != 200) {
      throw StateError('服务端音乐选择失败：${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = body['id'] as String;
    final selectedMood = MusicMood.values.firstWhere(
      (value) => value.name == body['mood'],
      orElse: () => mood,
    );
    final dir = Directory(cacheDir);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$id.mp3'));
    if (!await file.exists() || await file.length() < 4096) {
      final contentUrl = body['contentUrl'] as String;
      final content = await http.get(
        Uri.parse(baseUrl).resolve(contentUrl),
        headers: _headers,
      );
      if (content.statusCode != 200) {
        throw StateError('服务端音乐下载失败：${content.statusCode}');
      }
      await file.writeAsBytes(content.bodyBytes, flush: true);
    }
    return MusicTrack(
      file: file,
      title: body['title'] as String? ?? selectedMood.label,
      mood: selectedMood,
    );
  }
}
