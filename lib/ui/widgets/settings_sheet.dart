import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../services/nas_photo_source.dart';
import '../../services/photo_index_service.dart';
import '../../services/photo_service.dart';
import '../../services/weather_service.dart';
import '../../voice/asr_client.dart';
import '../../voice/tts_service.dart';

/// 设置浮层：城市、相册目录、ASR、TTS 语音、轮播间隔、NAS 相册。
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<ConfigService>(),
        child: const Dialog(
          backgroundColor: Color(0xFF1e2228),
          child: SettingsSheet(),
        ),
      ),
    );
  }

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _city;
  late final TextEditingController _photoDir;
  late final TextEditingController _asrBaseUrl;
  late final TextEditingController _asrApiKey;
  late final TextEditingController _asrModel;
  late final TextEditingController _ttsVoice;
  late final TextEditingController _slideshowSeconds;
  late final TextEditingController _nasUrl;
  late final TextEditingController _nasUser;
  late final TextEditingController _nasPassword;
  late final TextEditingController _nasRemoteDir;
  late final TextEditingController _nasKeywords;

  bool _nasEnabled = false;
  bool _nasFilterEnabled = true;

  /// 测试连接的行内反馈（null 表示尚未测试）
  String? _nasTestResult;
  bool _nasTesting = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<ConfigService>().config;
    _city = TextEditingController(text: c.city);
    _photoDir = TextEditingController(text: c.photoDir);
    _asrBaseUrl = TextEditingController(text: c.asrBaseUrl);
    _asrApiKey = TextEditingController(text: c.asrApiKey);
    _asrModel = TextEditingController(text: c.asrModel);
    _ttsVoice = TextEditingController(text: c.ttsVoice);
    _slideshowSeconds =
        TextEditingController(text: '${c.slideshowSeconds}');
    _nasUrl = TextEditingController(text: c.nasWebdavUrl);
    _nasUser = TextEditingController(text: c.nasWebdavUser);
    _nasPassword = TextEditingController(text: c.nasWebdavPassword);
    _nasRemoteDir = TextEditingController(text: c.nasRemoteDir);
    _nasKeywords =
        TextEditingController(text: c.nasFilterKeywords.join(', '));
    _nasEnabled = c.nasEnabled;
    _nasFilterEnabled = c.nasFilterEnabled;
  }

  @override
  void dispose() {
    for (final c in [
      _city, _photoDir, _asrBaseUrl, _asrApiKey, _asrModel,
      _ttsVoice, _slideshowSeconds,
      _nasUrl, _nasUser, _nasPassword, _nasRemoteDir, _nasKeywords,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 用当前填写的值建临时实例测试连接，不影响运行中的共享 nasSource
  Future<void> _testConnection() async {
    setState(() {
      _nasTesting = true;
      _nasTestResult = null;
    });
    final probe = NasPhotoSource()
      ..configure(
        url: _nasUrl.text.trim(),
        user: _nasUser.text.trim(),
        password: _nasPassword.text,
        remoteDir: _nasRemoteDir.text.trim(),
      );
    try {
      await probe.ping();
      if (mounted) setState(() => _nasTestResult = '连接成功');
    } catch (e) {
      if (mounted) setState(() => _nasTestResult = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _nasTesting = false);
    }
  }

  Future<void> _save() async {
    // 先同步取到引用，避免跨 async 间隙使用 context
    final configService = context.read<ConfigService>();
    final weather = context.read<WeatherService>();
    final photos = context.read<PhotoService>();
    final nas = context.read<NasPhotoSource>();
    final tts = context.read<TtsService>();
    final asr = context.read<AsrClient>();
    final photoIndex = context.read<PhotoIndexService>();
    final navigator = Navigator.of(context);

    final c = configService.config;
    c.city = _city.text.trim();
    c.photoDir = _photoDir.text.trim();
    c.asrBaseUrl = _asrBaseUrl.text.trim();
    c.asrApiKey = _asrApiKey.text.trim();
    c.asrModel = _asrModel.text.trim();
    c.ttsVoice = _ttsVoice.text.trim();
    c.slideshowSeconds = int.tryParse(_slideshowSeconds.text.trim()) ?? 10;
    c.nasEnabled = _nasEnabled;
    c.nasWebdavUrl = _nasUrl.text.trim();
    c.nasWebdavUser = _nasUser.text.trim();
    c.nasWebdavPassword = _nasPassword.text; // 密码不 trim，保留原样
    c.nasRemoteDir = _nasRemoteDir.text.trim();
    c.nasFilterEnabled = _nasFilterEnabled;
    c.nasFilterKeywords = _nasKeywords.text
        .split(RegExp('[,，]')) // 中英文逗号都作分隔
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    await configService.save();

    // 即时生效的部分
    await weather.setCity(c.city);
    await photos.setDir(c.photoDir);
    photos.startSlideshow(c.slideshowSeconds);
    // NAS：按新配置重建客户端并应用（内部按 nasEnabled 决定是否真连）
    nas.configure(
        url: c.nasWebdavUrl,
        user: c.nasWebdavUser,
        password: c.nasWebdavPassword,
        remoteDir: c.nasRemoteDir);
    await photos.applyNasConfig(c, nas);
    photoIndex.applyConfig(c);
    tts.voice = c.ttsVoice;
    asr
      ..baseUrl = c.asrBaseUrl
      ..apiKey = c.asrApiKey
      ..model = c.asrModel;

    navigator.pop();
  }

  Widget _field(String label, TextEditingController controller,
      {bool obscure = false, String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Colors.white54),
          hintStyle: const TextStyle(color: Colors.white24),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.blue)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 460,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('设置',
                style: TextStyle(fontSize: 22, color: Colors.white)),
            const SizedBox(height: 16),
            _field('天气城市', _city),
            _field('相册目录', _photoDir),
            _field('轮播间隔（秒）', _slideshowSeconds),
            _field('语音识别 API 地址', _asrBaseUrl,
                hint: 'https://api.openai.com/v1'),
            _field('语音识别 API Key', _asrApiKey, obscure: true),
            _field('语音识别模型', _asrModel),
            _field('TTS 语音', _ttsVoice),
            const Divider(height: 32, color: Colors.white24),
            const Text('NAS 相册',
                style: TextStyle(fontSize: 16, color: Colors.white70)),
            SwitchListTile(
              title: const Text('启用 NAS 相册',
                  style: TextStyle(color: Colors.white)),
              value: _nasEnabled,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setState(() => _nasEnabled = v),
            ),
            _field('WebDAV 地址', _nasUrl, hint: 'http://192.168.1.22:5005'),
            _field('WebDAV 账号', _nasUser),
            _field('WebDAV 密码', _nasPassword, obscure: true),
            _field('远程照片目录', _nasRemoteDir, hint: '/photo'),
            SwitchListTile(
              title: const Text('过滤截图等文件',
                  style: TextStyle(color: Colors.white)),
              value: _nasFilterEnabled,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setState(() => _nasFilterEnabled = v),
            ),
            _field('过滤关键词（逗号分隔）', _nasKeywords,
                hint: '截图, screenshot, 屏幕快照'),
            Row(
              children: [
                TextButton(
                  onPressed: _nasTesting ? null : _testConnection,
                  child: Text(_nasTesting ? '测试中…' : '测试连接'),
                ),
                if (_nasTestResult != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _nasTestResult!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _nasTestResult == '连接成功'
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ),
    );
  }
}
