import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:smart_frame/core/config/app_config.dart';

bool validAgentUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

String normalizeAgentUrl(String value) =>
    value.trim().replaceFirst(RegExp(r'/+$'), '');

bool validDisplayNodeConfig(AppConfig config) =>
    validAgentUrl(config.agentUrl) &&
    config.nodeId.isNotEmpty &&
    config.roomId.isNotEmpty &&
    config.deviceKey.isNotEmpty;

class AndroidSetupApp extends StatelessWidget {
  const AndroidSetupApp({
    super.key,
    required this.configService,
    required this.onConfigured,
  });

  final ConfigService configService;
  final Future<void> Function() onConfigured;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '智能屏设置',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _AndroidSetupPage(
      configService: configService,
      onConfigured: onConfigured,
    ),
  );
}

class _AndroidSetupPage extends StatefulWidget {
  const _AndroidSetupPage({
    required this.configService,
    required this.onConfigured,
  });

  final ConfigService configService;
  final Future<void> Function() onConfigured;

  @override
  State<_AndroidSetupPage> createState() => _AndroidSetupPageState();
}

class _AndroidSetupPageState extends State<_AndroidSetupPage> {
  late final TextEditingController _url;
  late final TextEditingController _pairingCode;
  late final TextEditingController _deviceName;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.configService.config.agentUrl);
    _pairingCode = TextEditingController();
    _deviceName = TextEditingController(text: '天猫精灵智能相册');
  }

  @override
  void dispose() {
    _url.dispose();
    _pairingCode.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final value = normalizeAgentUrl(_url.text);
    if (!validAgentUrl(value)) {
      setState(() => _error = '请输入完整地址，例如 http://192.168.1.9:8790');
      return;
    }
    if (_pairingCode.text.trim().isEmpty || _deviceName.text.trim().isEmpty) {
      setState(() => _error = '请输入配对码和设备名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ready = await http
          .get(Uri.parse('$value/health/ready'))
          .timeout(const Duration(seconds: 5));
      if (ready.statusCode != 200) {
        throw Exception('健康检查 HTTP ${ready.statusCode}');
      }
      final response = await http
          .post(
            Uri.parse('$value/api/v1/nodes/pair'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': _pairingCode.text.trim(),
              'name': _deviceName.text.trim(),
              'platform': 'android',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 201) {
        throw Exception('配对 HTTP ${response.statusCode}');
      }
      final paired = jsonDecode(response.body) as Map<String, dynamic>;
      widget.configService.config
        ..serverRole = 'display'
        ..agentUrl = value
        ..nodeId = paired['nodeId'] as String
        ..roomId = paired['roomId'] as String
        ..deviceKey = paired['deviceKey'] as String;
      await widget.configService.save();
      if (!mounted) return;
      await widget.onConfigured();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '无法连接或配对家庭服务：$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101318),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.photo_library_outlined,
                  size: 64,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(height: 20),
                const Text(
                  '连接家庭相册服务',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Android 只负责展示、录音和播放；照片、音乐与语音 Agent 由家庭服务器提供。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _url,
                  enabled: !_saving,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '家庭服务地址',
                    hintText: 'http://192.168.1.9:8790',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saving ? null : _connect(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pairingCode,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '配对码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _deviceName,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '设备名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _saving ? null : _connect,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(_saving ? '正在测试连接…' : '连接并启动'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
