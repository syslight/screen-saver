import 'package:flutter/material.dart';

import '../api/home_admin_api.dart';
import '../models/family_server.dart';

typedef ParentLogin =
    Future<void> Function(
      FamilyServer server,
      String username,
      String password,
    );
typedef ParentBootstrap =
    Future<void> Function(
      FamilyServer server,
      String householdName,
      String username,
      String password,
    );
typedef ParentEnroll =
    Future<void> Function(FamilyServer server, String enrollmentCode);

class LoginPage extends StatefulWidget {
  const LoginPage({
    required this.onLogin,
    required this.onBootstrap,
    required this.onEnroll,
    super.key,
  });

  final ParentLogin onLogin;
  final ParentBootstrap onBootstrap;
  final ParentEnroll onEnroll;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onLogin(
        parseFamilyServer(_server.text),
        _username.text,
        _password.text,
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } on HomeAdminApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bootstrap() async {
    try {
      final server = parseFamilyServer(_server.text);
      if (server.isCloud) {
        throw const FormatException('云平台请使用一次性绑定码；家庭初始化只能在家中服务器进行');
      }
      final values = await showDialog<(String, String, String)>(
        context: context,
        builder: (_) => const _BootstrapDialog(),
      );
      if (values == null) return;
      setState(() {
        _loading = true;
        _error = null;
      });
      await widget.onBootstrap(server, values.$1, values.$2, values.$3);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } on HomeAdminApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enroll() async {
    try {
      final server = parseFamilyServer(_server.text);
      if (!server.isCloud) {
        throw const FormatException('远程绑定请输入 HTTPS 云平台地址');
      }
      final code = await showDialog<String>(
        context: context,
        builder: (_) => const _EnrollmentDialog(),
      );
      if (code == null) return;
      setState(() {
        _loading = true;
        _error = null;
      });
      await widget.onEnroll(server, code);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } on HomeAdminApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
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
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.home_rounded, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'HomeAdmin',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '登录后管理家里的智能屏和家庭 Agent',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _server,
                      decoration: const InputDecoration(
                        labelText: '家庭服务器地址',
                        hintText: '192.168.1.9 或 https://home.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      keyboardType: TextInputType.url,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入家庭服务器地址'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: '家长账号',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入家长账号'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidePassword,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) =>
                          value == null || value.isEmpty ? '请输入密码' : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _loading ? null : _submit,
                      icon: _loading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 13),
                        child: Text('登录家庭服务器'),
                      ),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _enroll,
                      child: const Text('使用一次性绑定码连接云平台'),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _bootstrap,
                      child: const Text('第一次使用？初始化家庭'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '在家优先局域网直连；外网只连接 HTTPS 云平台，不要把家庭服务端口暴露到公网。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EnrollmentDialog extends StatefulWidget {
  const _EnrollmentDialog();

  @override
  State<_EnrollmentDialog> createState() => _EnrollmentDialogState();
}

class _EnrollmentDialogState extends State<_EnrollmentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('绑定这台家长手机'),
    content: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请输入已登录 HomeAdmin生成的 8 位一次性绑定码。绑定码约 10 分钟内有效，使用后立即失效。'),
          const SizedBox(height: 16),
          TextFormField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '一次性绑定码',
              hintText: '例如 7K4M9Q2X',
              prefixIcon: Icon(Icons.key_outlined),
            ),
            validator: (value) {
              final normalized = value?.replaceAll(RegExp(r'[\s-]'), '') ?? '';
              return normalized.length < 8 ? '请输入完整的 8 位绑定码' : null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('绑定')),
    ],
  );

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _code.text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase(),
    );
  }
}

class _BootstrapDialog extends StatefulWidget {
  const _BootstrapDialog();

  @override
  State<_BootstrapDialog> createState() => _BootstrapDialogState();
}

class _BootstrapDialogState extends State<_BootstrapDialog> {
  final _formKey = GlobalKey<FormState>();
  final _household = TextEditingController(text: '我们的家');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _household.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('初始化家庭'),
    content: SingleChildScrollView(
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _household,
              decoration: const InputDecoration(labelText: '家庭名称'),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: '第一个家长账号'),
              validator: (value) =>
                  (value?.trim().length ?? 0) < 2 ? '账号至少 2 个字符' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码（至少 10 位）'),
              validator: (value) =>
                  (value?.length ?? 0) < 10 ? '密码至少 10 位' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再次输入密码'),
              validator: (value) => value != _password.text ? '两次密码不一致' : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_formKey.currentState!.validate()) return;
          Navigator.pop(context, (
            _household.text.trim(),
            _username.text.trim(),
            _password.text,
          ));
        },
        child: const Text('创建家庭'),
      ),
    ],
  );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;
}
