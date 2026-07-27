class FamilyServer {
  const FamilyServer({required this.scheme, required this.host, this.port});

  final String scheme;
  final String host;
  final int? port;

  bool get isCloud => scheme == 'https';
  bool get supportsDirectFrame => !isCloud;

  String get displayName => Uri(
    scheme: scheme,
    host: host,
    port: port,
  ).toString().replaceFirst(RegExp(r'/$'), '');

  String get agentBaseUrl => Uri(
    scheme: scheme,
    host: host,
    port: port ?? (isCloud ? null : 8790),
  ).toString().replaceFirst(RegExp(r'/$'), '');

  String? get frameBaseUrl =>
      supportsDirectFrame ? _localUrl(8780, webSocket: false) : null;
  String? get frameWebSocketUrl => supportsDirectFrame
      ? _localUrl(8780, webSocket: true, path: '/ws')
      : null;

  String _localUrl(
    int targetPort, {
    required bool webSocket,
    String path = '',
  }) {
    return Uri(
      scheme: webSocket ? 'ws' : 'http',
      host: host,
      port: targetPort,
      path: path,
    ).toString();
  }

  Map<String, dynamic> toJson() => {
    'scheme': scheme,
    'host': host,
    if (port != null) 'port': port,
  };

  factory FamilyServer.fromJson(Map<String, dynamic> json) => FamilyServer(
    scheme: json['scheme'] as String? ?? 'http',
    host: json['host'] as String? ?? '',
    port: json['port'] as int?,
  );
}

FamilyServer parseFamilyServer(String input) {
  var value = input.trim();
  if (value.isEmpty) throw const FormatException('请输入家庭服务器地址');
  if (!value.contains('://')) value = 'http://$value';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('地址格式不正确，例如 192.168.1.9');
  }
  return FamilyServer(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

class ParentSession {
  const ParentSession({
    required this.server,
    required this.token,
    required this.expiresAt,
    required this.userId,
    required this.householdId,
  });

  final FamilyServer server;
  final String token;
  final DateTime expiresAt;
  final String userId;
  final String householdId;

  bool get expired => !expiresAt.isAfter(DateTime.now());
}
