import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 创建尊重 http_proxy/HTTP_PROXY 环境变量的 HTTP 客户端
/// （dart:io 默认不走系统代理，这里显式开启）。
http.Client createHttpClient() {
  final env = Platform.environment;
  final hasProxy = (env['http_proxy'] ?? env['HTTP_PROXY'] ?? '').isNotEmpty;
  if (!hasProxy) return http.Client();
  final hc = HttpClient()
    ..findProxy =
        (uri) => HttpClient.findProxyFromEnvironment(uri, environment: env);
  return IOClient(hc);
}
