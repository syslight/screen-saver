import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/home_admin_api.dart';
import '../models/family_server.dart';

class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({
    required this.server,
    required this.token,
    required this.apiBuilder,
    super.key,
  });

  final FamilyServer server;
  final String token;
  final HomeAdminApi Function(FamilyServer server) apiBuilder;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  static const _kinds = ['asr', 'tts', 'llm'];
  static const _kindLabels = {
    'asr': '语音识别 ASR',
    'tts': '语音合成 TTS',
    'llm': '大语言模型 LLM',
  };
  static const _sectionLabels = {
    'credential': '连接凭据',
    'model': '模型与语言',
    'voice': '音色与角色',
    'parameter': '生成参数',
    'advanced': '高级连接参数',
  };

  final _controllers = <String, TextEditingController>{};
  final _clearSecrets = <String>{};
  final _booleanValues = <String, bool>{};
  ProviderSnapshot? _snapshot;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _fieldKey(String kind, String provider, String field) =>
      '$kind.$provider.$field';

  Future<T> _request<T>(Future<T> Function(HomeAdminApi api) operation) async {
    final api = widget.apiBuilder(widget.server);
    try {
      return await operation(api);
    } finally {
      api.close();
    }
  }

  void _syncEditors(ProviderSnapshot snapshot) {
    for (final kind in _kinds) {
      for (final provider in snapshot.providers[kind]!) {
        for (final field in provider.fields) {
          final key = _fieldKey(kind, provider.name, field.name);
          if (field.type == 'boolean') {
            _booleanValues[key] = field.value as bool? ?? false;
            continue;
          }
          final controller = _controllers.putIfAbsent(
            key,
            TextEditingController.new,
          );
          controller.text = field.secret
              ? field.configured
                    ? field.hint ?? '已脱敏'
                    : ''
              : '${field.value ?? ''}';
        }
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await _request(
        (api) => api.getProviderStatus(widget.token),
      );
      if (!mounted) return;
      _syncEditors(snapshot);
      setState(() => _snapshot = snapshot);
    } on HomeAdminApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSelection() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    setState(() => _saving = true);
    try {
      final result = await _request(
        (api) => api.updateProviderSelection(
          widget.token,
          asr: snapshot.selection['asr']!,
          tts: snapshot.selection['tts']!,
          llm: snapshot.selection['llm']!,
        ),
      );
      if (!mounted) return;
      _syncEditors(result);
      setState(() => _snapshot = result);
      _notice('语音链路已切换');
    } on HomeAdminApiException catch (error) {
      _notice(error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  dynamic _fieldValue(ProviderField field, String text) {
    if (field.type != 'number') return text.trim();
    final value = num.tryParse(text.trim());
    if (value == null) throw FormatException('${field.label}必须是数字');
    if (field.minimum != null && value < field.minimum!) {
      throw FormatException('${field.label}不能小于 ${field.minimum}');
    }
    if (field.maximum != null && value > field.maximum!) {
      throw FormatException('${field.label}不能大于 ${field.maximum}');
    }
    return field.value is int ? value.toInt() : value.toDouble();
  }

  Future<void> _saveProvider(String kind, ProviderOption provider) async {
    final values = <String, dynamic>{};
    final clear = <String>[];
    try {
      for (final field in provider.fields) {
        final key = _fieldKey(kind, provider.name, field.name);
        if (field.type == 'boolean') {
          values[field.name] = _booleanValues[key] ?? false;
          continue;
        }
        if (field.secret && _clearSecrets.contains(key)) {
          clear.add(field.name);
          continue;
        }
        final text = _controllers[key]?.text ?? '';
        final displayedSecret = field.hint ?? '已脱敏';
        if (field.secret &&
            (text.trim().isEmpty || text.trim() == displayedSecret)) {
          continue;
        }
        if (field.required && text.trim().isEmpty) {
          throw FormatException('${field.label}不能为空');
        }
        if (text.trim().isNotEmpty) {
          values[field.name] = _fieldValue(field, text);
        }
      }
    } on FormatException catch (error) {
      _notice(error.message, error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await _request(
        (api) => api.updateProviderConfiguration(
          widget.token,
          kind: kind,
          name: provider.name,
          values: values,
          clear: clear,
        ),
      );
      if (!mounted) return;
      _clearSecrets.removeWhere(
        (key) => key.startsWith('$kind.${provider.name}.'),
      );
      _syncEditors(result);
      setState(() => _snapshot = result);
      _notice('${provider.label}配置已保存');
    } on HomeAdminApiException catch (error) {
      _notice(error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _check(String kind, ProviderOption provider) async {
    setState(() => _saving = true);
    try {
      final result = await _request(
        (api) =>
            api.checkProvider(widget.token, kind: kind, name: provider.name),
      );
      if (!mounted) return;
      _syncEditors(result);
      setState(() => _snapshot = result);
      _notice('${provider.label}检测完成');
    } on HomeAdminApiException catch (error) {
      _notice(error.message, error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notice(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AI Provider'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _loading && _snapshot == null
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _snapshot == null
        ? Center(child: Text(_error!))
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _selectionCard(),
              const SizedBox(height: 12),
              for (final kind in _kinds) ...[
                _kindSection(kind),
                const SizedBox(height: 12),
              ],
            ],
          ),
  );

  Widget _selectionCard() {
    final snapshot = _snapshot!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('当前语音链路', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '这里只决定下一轮调用哪个 Provider；各 Provider 的凭据和参数在下方独立管理。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final kind in _kinds) ...[
              DropdownButtonFormField<String>(
                initialValue: snapshot.selection[kind],
                decoration: InputDecoration(labelText: _kindLabels[kind]),
                items: snapshot.providers[kind]!
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.name,
                        child: Text(item.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => snapshot.selection[kind] = value ?? '',
                      ),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton(
              onPressed: _saving ? null : _saveSelection,
              child: const Text('应用语音链路'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kindSection(String kind) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _kindLabels[kind]!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 4),
          for (final provider in _snapshot!.providers[kind]!)
            _providerTile(kind, provider),
        ],
      ),
    ),
  );

  Widget _providerTile(String kind, ProviderOption provider) {
    final details = [
      '模型 ${provider.model}',
      if (provider.voice != null) '角色 ${provider.voice}',
      if (provider.language != null) '语言 ${provider.language}',
      if (provider.streaming) '流式',
    ].join(' · ');
    return ExpansionTile(
      initiallyExpanded: provider.active,
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        provider.state == 'healthy'
            ? Icons.check_circle
            : provider.configured
            ? Icons.pending
            : Icons.error_outline,
        color: provider.state == 'healthy'
            ? Colors.green
            : provider.configured
            ? Colors.orange
            : Colors.red,
      ),
      title: Text(provider.label),
      subtitle: Text(
        '$details${provider.message == null ? '' : '\n${provider.message}'}',
      ),
      trailing: provider.active
          ? const Chip(label: Text('当前启用'))
          : const Icon(Icons.expand_more),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final section in _sectionLabels.keys)
                if (provider.fields.any(
                  (field) => field.section == section,
                )) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 8),
                    child: Text(
                      _sectionLabels[section]!,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  for (final field in provider.fields.where(
                    (field) => field.section == section,
                  ))
                    _fieldEditor(kind, provider.name, field),
                ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _saveProvider(kind, provider),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存此 Provider'),
                  ),
                  OutlinedButton.icon(
                    onPressed: provider.configured && !_saving
                        ? () => _check(kind, provider)
                        : null,
                    icon: const Icon(Icons.health_and_safety_outlined),
                    label: const Text('单独检测'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fieldEditor(String kind, String provider, ProviderField field) {
    final key = _fieldKey(kind, provider, field.name);
    if (field.type == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: field.help == null ? null : Text(field.help!),
        value: _booleanValues[key] ?? false,
        onChanged: _saving
            ? null
            : (value) => setState(() => _booleanValues[key] = value),
      );
    }
    final controller = _controllers[key]!;
    final displayedSecret = field.hint ?? '已脱敏';
    final credentialStatus = field.secret
        ? field.configured
              ? '已配置 ${field.hint ?? '已脱敏'} · ${field.source == 'managed' ? '后台保存' : '环境变量'}'
              : '尚未配置'
        : null;
    final helper = [?credentialStatus, ?field.help].join('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            obscureText: field.secret && controller.text != displayedSecret,
            enabled: !_clearSecrets.contains(key),
            onTap: field.secret && field.configured
                ? () {
                    if (controller.text == displayedSecret) {
                      setState(controller.clear);
                    }
                  }
                : null,
            onChanged: field.secret ? (_) => setState(() {}) : null,
            keyboardType: field.type == 'number'
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            inputFormatters: field.type == 'number'
                ? [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))]
                : null,
            decoration: InputDecoration(
              labelText: '${field.label}${field.required ? ' *' : ''}',
              hintText: field.secret
                  ? field.configured
                        ? '输入新值可替换；留空保留现有值'
                        : '请输入凭据'
                  : null,
              helperText: helper.isEmpty ? null : helper,
              helperMaxLines: 3,
              suffixIcon: field.secret && field.configured
                  ? const Icon(
                      Icons.verified_user_outlined,
                      color: Colors.green,
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
          if (field.options.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final option in field.options)
                  ActionChip(
                    label: Text(option.label),
                    onPressed: _saving
                        ? null
                        : () => setState(
                            () => controller.text = '${option.value}',
                          ),
                  ),
              ],
            ),
            if (field.allowCustom)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '也可以直接输入供应商支持的自定义值。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          if (field.secret)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _clearSecrets.contains(key),
              title: const Text('清除此 Provider 的现有值'),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: _saving
                  ? null
                  : (checked) => setState(() {
                      if (checked == true) {
                        _clearSecrets.add(key);
                      } else {
                        _clearSecrets.remove(key);
                      }
                    }),
            ),
        ],
      ),
    );
  }
}
