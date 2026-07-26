import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:smart_frame/core/network/http_helper.dart';

/// OpenAI 兼容 Whisper API 客户端（/audio/transcriptions）。
class AsrClient {
  AsrClient({
    required this.baseUrl,
    required this.apiKey,
    this.model = 'whisper-1',
    http.Client? client,
  }) : _client = client ?? createHttpClient();

  // 可在设置页修改，即时生效
  String baseUrl;
  String apiKey;
  String model;
  final http.Client _client;

  bool get isConfigured => apiKey.isNotEmpty;

  /// 把一段 WAV 音频转成文字。
  Future<String> transcribe(Uint8List wavBytes) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/audio/transcriptions'),
    );
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = model;
    request.fields['language'] = 'zh';
    request.files.add(
      http.MultipartFile.fromBytes('file', wavBytes, filename: 'audio.wav'),
    );
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('ASR HTTP ${streamed.statusCode}: $body');
    }
    return ((jsonDecode(body) as Map<String, dynamic>)['text'] as String? ?? '')
        .trim();
  }
}
