import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/family_server.dart';

class HomeAdminApiException implements Exception {
  const HomeAdminApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CloudCapability {
  const CloudCapability({required this.type, required this.commands});

  final String type;
  final List<String> commands;

  factory CloudCapability.fromJson(Map<String, dynamic> json) =>
      CloudCapability(
        type: json['type'] as String? ?? '',
        commands: (json['commands'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

class CloudNode {
  const CloudNode({
    required this.id,
    required this.name,
    required this.status,
    required this.capabilities,
  });

  final String id;
  final String name;
  final String status;
  final List<CloudCapability> capabilities;

  bool supports(String capabilityType, String command) => capabilities.any(
    (capability) =>
        capability.type == capabilityType &&
        capability.commands.contains(command),
  );

  factory CloudNode.fromJson(Map<String, dynamic> json) => CloudNode(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '家庭节点',
    status: json['status'] as String? ?? 'offline',
    capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CloudCapability.fromJson)
        .toList(growable: false),
  );
}

class NodeCommandResult {
  const NodeCommandResult({
    required this.success,
    required this.result,
    this.errorCode,
  });

  final bool success;
  final Map<String, dynamic> result;
  final String? errorCode;
}

class ParentEnrollmentCode {
  const ParentEnrollmentCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;
}

class ProviderOption {
  const ProviderOption({
    required this.name,
    required this.label,
    required this.configured,
    required this.active,
    required this.streaming,
    required this.state,
    required this.model,
    required this.fields,
    this.voice,
    this.language,
    this.message,
    this.latencyMs,
  });

  final String name;
  final String label;
  final bool configured;
  final bool active;
  final bool streaming;
  final String state;
  final String model;
  final List<ProviderField> fields;
  final String? voice;
  final String? language;
  final String? message;
  final int? latencyMs;

  factory ProviderOption.fromJson(Map<String, dynamic> json) => ProviderOption(
    name: json['name'] as String? ?? '',
    label: json['label'] as String? ?? '',
    configured: json['configured'] as bool? ?? false,
    active: json['active'] as bool? ?? false,
    streaming: json['streaming'] as bool? ?? false,
    state: json['state'] as String? ?? 'unconfigured',
    model: json['model'] as String? ?? '',
    fields: (json['fields'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ProviderField.fromJson)
        .toList(growable: false),
    voice: json['voice'] as String?,
    language: json['language'] as String?,
    message: json['message'] as String?,
    latencyMs: json['latencyMs'] as int?,
  );
}

class ProviderFieldChoice {
  const ProviderFieldChoice({required this.value, required this.label});

  final dynamic value;
  final String label;

  factory ProviderFieldChoice.fromJson(Map<String, dynamic> json) =>
      ProviderFieldChoice(
        value: json['value'],
        label: json['label'] as String? ?? '',
      );
}

class ProviderField {
  const ProviderField({
    required this.name,
    required this.label,
    required this.type,
    required this.section,
    required this.required,
    required this.allowCustom,
    required this.options,
    required this.source,
    this.value,
    this.configured = false,
    this.hint,
    this.minimum,
    this.maximum,
    this.help,
  });

  final String name;
  final String label;
  final String type;
  final String section;
  final bool required;
  final bool allowCustom;
  final List<ProviderFieldChoice> options;
  final dynamic value;
  final bool configured;
  final String source;
  final String? hint;
  final num? minimum;
  final num? maximum;
  final String? help;

  bool get secret => type == 'secret';

  factory ProviderField.fromJson(Map<String, dynamic> json) => ProviderField(
    name: json['name'] as String? ?? '',
    label: json['label'] as String? ?? '',
    type: json['type'] as String? ?? 'text',
    section: json['section'] as String? ?? 'parameter',
    required: json['required'] as bool? ?? false,
    allowCustom: json['allowCustom'] as bool? ?? false,
    options: (json['options'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ProviderFieldChoice.fromJson)
        .toList(growable: false),
    value: json['value'],
    configured: json['configured'] as bool? ?? false,
    source: json['source'] as String? ?? '',
    hint: json['hint'] as String?,
    minimum: json['min'] as num?,
    maximum: json['max'] as num?,
    help: json['help'] as String?,
  );
}

class ProviderSnapshot {
  const ProviderSnapshot({required this.selection, required this.providers});

  final Map<String, String> selection;
  final Map<String, List<ProviderOption>> providers;

  factory ProviderSnapshot.fromJson(Map<String, dynamic> json) {
    final rawSelection = json['selection'] as Map<String, dynamic>? ?? const {};
    final rawProviders = json['providers'] as Map<String, dynamic>? ?? const {};
    return ProviderSnapshot(
      selection: rawSelection.map(
        (key, value) => MapEntry(key, value as String? ?? ''),
      ),
      providers: {
        for (final kind in const ['asr', 'tts', 'llm'])
          kind: (rawProviders[kind] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(ProviderOption.fromJson)
              .toList(growable: false),
      },
    );
  }
}

class HomeAdminApi {
  HomeAdminApi(this.server, {http.Client? client})
    : _client = client ?? http.Client();

  final FamilyServer server;
  final http.Client _client;

  Future<void> bootstrap({
    required String householdName,
    required String username,
    required String password,
  }) async {
    await _requestMap(
      'POST',
      '/api/v1/bootstrap',
      body: {
        'householdName': householdName.trim(),
        'timezone': 'Asia/Shanghai',
        'username': username.trim(),
        'password': password,
      },
    );
  }

  Future<ParentSession> login(String username, String password) async {
    final response = await _requestMap(
      'POST',
      '/api/v1/auth/login',
      body: {'username': username.trim(), 'password': password},
    );
    return _sessionFromResponse(response);
  }

  Future<ParentSession> enroll(
    String code, {
    required String deviceName,
    String platform = 'android',
  }) async {
    final response = await _requestMap(
      'POST',
      '/api/v1/auth/enroll',
      body: {
        'code': code.trim().toUpperCase(),
        'deviceName': deviceName.trim(),
        'platform': platform,
      },
    );
    return _sessionFromResponse(response);
  }

  Future<ParentEnrollmentCode> createEnrollmentCode(String token) async {
    final response = await _requestMap(
      'POST',
      '/api/v1/auth/enrollment-codes',
      token: token,
    );
    return ParentEnrollmentCode(
      code: response['code'] as String,
      expiresAt: DateTime.parse(response['expiresAt'] as String),
    );
  }

  Future<List<CloudNode>> listNodes(String token) async {
    final response = await _requestJson('GET', '/api/v1/nodes', token: token);
    if (response is! List<dynamic>) {
      throw const HomeAdminApiException('服务器返回了无法识别的节点列表');
    }
    return response
        .whereType<Map<String, dynamic>>()
        .map(CloudNode.fromJson)
        .toList(growable: false);
  }

  Future<NodeCommandResult> sendNodeCommand(
    String token,
    String nodeId,
    String commandName, {
    Map<String, dynamic> arguments = const {},
  }) async {
    final response = await _requestMap(
      'POST',
      '/api/v1/nodes/${Uri.encodeComponent(nodeId)}/commands',
      token: token,
      body: {'commandName': commandName, 'arguments': arguments},
    );
    return NodeCommandResult(
      success: response['success'] as bool? ?? false,
      result: response['result'] is Map<String, dynamic>
          ? response['result'] as Map<String, dynamic>
          : const {},
      errorCode: response['errorCode'] as String?,
    );
  }

  Future<void> logout(String token) async {
    await _requestMap('POST', '/api/v1/auth/logout', token: token);
  }

  Future<ProviderSnapshot> getProviderStatus(String token) async =>
      ProviderSnapshot.fromJson(
        await _requestMap('GET', '/api/v1/admin/providers', token: token),
      );

  Future<ProviderSnapshot> updateProviderSelection(
    String token, {
    required String asr,
    required String tts,
    required String llm,
  }) async => ProviderSnapshot.fromJson(
    await _requestMap(
      'PUT',
      '/api/v1/admin/providers/selection',
      token: token,
      body: {'asr': asr, 'tts': tts, 'llm': llm},
    ),
  );

  Future<ProviderSnapshot> updateProviderCredentials(
    String token, {
    required Map<String, String> values,
    required List<String> clear,
  }) async => ProviderSnapshot.fromJson(
    await _requestMap(
      'PUT',
      '/api/v1/admin/providers/credentials',
      token: token,
      body: {...values, 'clear': clear},
    ),
  );

  Future<ProviderSnapshot> updateProviderConfiguration(
    String token, {
    required String kind,
    required String name,
    required Map<String, dynamic> values,
    required List<String> clear,
  }) async => ProviderSnapshot.fromJson(
    await _requestMap(
      'PUT',
      '/api/v1/admin/providers/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(name)}/configuration',
      token: token,
      body: {'values': values, 'clear': clear},
    ),
  );

  Future<ProviderSnapshot> checkProvider(
    String token, {
    required String kind,
    required String name,
  }) async => ProviderSnapshot.fromJson(
    await _requestMap(
      'POST',
      '/api/v1/admin/providers/check',
      token: token,
      body: {'kind': kind, 'name': name},
    ),
  );

  ParentSession _sessionFromResponse(Map<String, dynamic> response) =>
      ParentSession(
        server: server,
        token: response['token'] as String,
        expiresAt: DateTime.parse(response['expiresAt'] as String),
        userId: response['userId'] as String,
        householdId: response['householdId'] as String,
      );

  Future<Map<String, dynamic>> _requestMap(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final data = await _requestJson(method, path, body: body, token: token);
    if (data is! Map<String, dynamic>) {
      throw const HomeAdminApiException('服务器返回了无法识别的数据');
    }
    return data;
  }

  Future<dynamic> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('${server.agentBaseUrl}$path'),
    );
    request.headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(streamed);
      dynamic data;
      try {
        data = response.bodyBytes.isEmpty
            ? const <String, dynamic>{}
            : jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        data = const <String, dynamic>{};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = data is Map<String, dynamic>
            ? data
            : const <String, dynamic>{};
        final detail = error['detail'];
        throw HomeAdminApiException(
          error['message'] as String? ??
              (detail is Map ? detail['message'] as String? : null) ??
              '登录失败 (${response.statusCode})',
          statusCode: response.statusCode,
        );
      }
      return data;
    } on TimeoutException {
      throw HomeAdminApiException(
        server.isCloud ? '连接云平台超时，请检查网络' : '连接超时，请确认手机和家庭服务器在同一 Wi-Fi',
      );
    } on HomeAdminApiException {
      rethrow;
    } on http.ClientException {
      throw HomeAdminApiException(
        server.isCloud ? '无法连接云平台，请检查地址和网络' : '无法连接家庭服务器，请检查地址和 Wi-Fi',
      );
    } on IOException {
      throw HomeAdminApiException(
        server.isCloud ? '无法连接云平台，请检查地址和网络' : '无法连接家庭服务器，请检查地址和 Wi-Fi',
      );
    }
  }

  void close() => _client.close();
}
