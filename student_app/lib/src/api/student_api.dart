import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../models/homework.dart';

class StudentApiException implements Exception {
  const StudentApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

String normalizeServerUrl(String input) {
  var value = input.trim();
  if (value.isEmpty) {
    throw const FormatException('请输入家庭服务器地址');
  }
  if (!value.contains('://')) {
    value = 'http://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('服务器地址格式不正确，例如 192.168.1.10:8790');
  }
  return uri.replace(path: '').toString().replaceAll(RegExp(r'/$'), '');
}

class StudentApi {
  StudentApi({required this.baseUrl, this.deviceKey, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final String? deviceKey;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (deviceKey != null) 'Authorization': 'Student $deviceKey',
  };

  Future<DeviceCredentials> pair({
    required String code,
    required String deviceName,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/student/pair',
      body: {
        'code': code.trim(),
        'name': deviceName.trim(),
        'platform': 'android',
      },
    );
    return DeviceCredentials(
      baseUrl: baseUrl,
      deviceId: json['deviceId'] as String,
      deviceKey: json['deviceKey'] as String,
      childId: json['childId'] as String,
      childName: json['childName'] as String,
    );
  }

  Future<StudentProfile> me() async =>
      StudentProfile.fromJson(await _jsonRequest('GET', '/api/v1/student/me'));

  Future<List<HomeworkTask>> listTasks() async {
    final response = await _send('GET', '/api/v1/student/homework/tasks');
    return (response as List<dynamic>)
        .map((item) => HomeworkTask.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<HomeworkTask> getTask(String taskId) async => HomeworkTask.fromJson(
    await _jsonRequest('GET', '/api/v1/student/homework/tasks/$taskId'),
  );

  Future<HomeworkTask> startTask(String taskId) async => HomeworkTask.fromJson(
    await _jsonRequest('POST', '/api/v1/student/homework/tasks/$taskId/start'),
  );

  Future<List<HomeworkSubmission>> listSubmissions(String taskId) async {
    final response = await _send(
      'GET',
      '/api/v1/student/homework/tasks/$taskId/submissions',
    );
    return (response as List<dynamic>)
        .map(
          (item) => HomeworkSubmission.fromJson(item as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  Future<HomeworkSubmission> submit(String taskId, List<XFile> photos) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/v1/student/homework/tasks/$taskId/submissions'),
    );
    request.headers.addAll(_headers);
    for (final photo in photos) {
      request.files.add(await http.MultipartFile.fromPath('files', photo.path));
    }
    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 90));
      final response = await http.Response.fromStream(streamed);
      final decoded = _decode(response);
      if (decoded is! Map<String, dynamic>) {
        throw const StudentApiException('服务器返回了无法识别的数据');
      }
      return HomeworkSubmission.fromJson(decoded);
    } on TimeoutException {
      throw const StudentApiException('上传超时，请确认与家庭服务器在同一 Wi-Fi');
    } on StudentApiException {
      rethrow;
    } on http.ClientException {
      throw const StudentApiException('无法连接家庭服务器，请检查 Wi-Fi 和服务器地址');
    } on IOException {
      throw const StudentApiException('无法连接家庭服务器，请检查 Wi-Fi 和服务器地址');
    }
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final response = await _send(method, path, body: body);
    if (response is! Map<String, dynamic>) {
      throw const StudentApiException('服务器返回了无法识别的数据');
    }
    return response;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      return _decode(await http.Response.fromStream(streamed));
    } on TimeoutException {
      throw const StudentApiException('请求超时，请确认与家庭服务器在同一 Wi-Fi');
    } on StudentApiException {
      rethrow;
    } on http.ClientException {
      throw const StudentApiException('无法连接家庭服务器，请检查 Wi-Fi 和服务器地址');
    } on IOException {
      throw const StudentApiException('无法连接家庭服务器，请检查 Wi-Fi 和服务器地址');
    }
  }

  dynamic _decode(http.Response response) {
    dynamic data;
    try {
      data = response.bodyBytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = data is Map<String, dynamic>
          ? data
          : const <String, dynamic>{};
      throw StudentApiException(
        error['message'] as String? ?? '请求失败 (${response.statusCode})',
        statusCode: response.statusCode,
        code: error['code'] as String?,
      );
    }
    return data;
  }

  void close() => _client.close();
}
