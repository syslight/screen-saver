import 'package:flutter/material.dart';

import '../api/student_api.dart';
import '../app.dart';
import '../models/homework.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    required this.apiBuilder,
    required this.onPaired,
    super.key,
  });

  final StudentApiBuilder apiBuilder;
  final Future<void> Function(DeviceCredentials credentials) onPaired;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: '学习平板');
  var _submitting = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (!_formKey.currentState!.validate()) return;
    String baseUrl;
    try {
      baseUrl = normalizeServerUrl(_serverController.text);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = widget.apiBuilder(baseUrl, null);
      final credentials = await api.pair(
        code: _codeController.text,
        deviceName: _nameController.text,
      );
      await widget.onPaired(credentials);
    } on StudentApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.school_rounded,
                          size: 64,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '连接家庭学习助手',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '请让家长在“家庭作业中心 → 学生平板”生成一次性配对码。',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          key: const Key('serverField'),
                          controller: _serverController,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: '家庭服务器地址',
                            hintText: '192.168.1.10:8790',
                            prefixIcon: Icon(Icons.dns_outlined),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请输入家庭服务器地址'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          key: const Key('pairingCodeField'),
                          controller: _codeController,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: '一次性配对码',
                            prefixIcon: Icon(Icons.key_outlined),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请输入家长生成的配对码'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: '设备名称',
                            prefixIcon: Icon(Icons.tablet_android_outlined),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请输入设备名称'
                              : null,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _error!,
                            key: const Key('pairingError'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('pairButton'),
                          onPressed: _submitting ? null : _pair,
                          icon: _submitting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.link),
                          label: Text(_submitting ? '正在连接…' : '配对平板'),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '当前版本仅供同一可信 Wi-Fi 使用，请勿把服务器端口开放到公网。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
