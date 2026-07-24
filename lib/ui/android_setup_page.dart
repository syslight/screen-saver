import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

bool validComputeNodeUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

String normalizeComputeNodeUrl(String value) =>
    value.trim().replaceFirst(RegExp(r'/+$'), '');

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
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(
      text: widget.configService.config.computeNodeUrl,
    );
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final value = normalizeComputeNodeUrl(_url.text);
    if (!validComputeNodeUrl(value)) {
      setState(() => _error = '请输入完整地址，例如 http://192.168.1.9:8780');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http
          .get(Uri.parse('$value/api/index/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      widget.configService.config
        ..serverRole = 'display'
        ..computeNodeUrl = value;
      await widget.configService.save();
      if (!mounted) return;
      await widget.onConfigured();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '无法连接计算节点：$e');
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
                  '连接智能屏计算节点',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Android 负责展示和录音，照片、索引和语音服务由同一局域网内的计算节点提供。',
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
                    labelText: '计算节点地址',
                    hintText: 'http://192.168.1.9:8780',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saving ? null : _connect(),
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
