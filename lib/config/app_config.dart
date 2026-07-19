import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 应用配置。所有字段有默认值，零配置可启动。
class AppConfig {
  AppConfig({
    this.city = '北京',
    this.photoDir = '',
    this.serverPort = 8780,
    this.slideshowSeconds = 10,
    this.weatherRefreshMinutes = 30,
    this.listenSeconds = 5,
    this.asrBaseUrl = 'https://api.openai.com/v1',
    this.asrApiKey = '',
    this.asrModel = 'whisper-1',
    this.ttsVoice = 'zh-CN-XiaoxiaoNeural',
    this.volume = 0.8,
    this.wakeWordModelDir = '',
    this.nasEnabled = false,
    this.nasWebdavUrl = 'http://192.168.1.22:5005',
    this.nasWebdavUser = '',
    this.nasWebdavPassword = '',
    this.nasRemoteDir = '',
    this.nasFilterEnabled = true,
    this.nasFilterKeywords = const ['截图', 'screenshot', '屏幕快照', '收集'],
  });

  /// 天气城市名（Open-Meteo 地理编码）
  String city;

  /// 相册目录（手机上传的照片也存这里）
  String photoDir;

  /// 手机控制台端口
  int serverPort;

  /// 相册轮播间隔（秒）
  int slideshowSeconds;

  /// 天气刷新间隔（分钟）
  int weatherRefreshMinutes;

  /// 唤醒后聆听时长（秒）
  int listenSeconds;

  /// OpenAI 兼容 Whisper API（可指向 Groq 等）
  String asrBaseUrl;
  String asrApiKey;
  String asrModel;

  /// edge-tts 语音名
  String ttsVoice;

  /// 播报音量 0..1
  double volume;

  /// sherpa-onnx KWS 唤醒词模型目录
  String wakeWordModelDir;

  /// 是否启用 NAS 相册来源
  bool nasEnabled;

  /// NAS WebDAV 地址
  String nasWebdavUrl;

  /// NAS WebDAV 账号
  String nasWebdavUser;

  /// NAS WebDAV 密码（本地明文存储，局域网场景）
  String nasWebdavPassword;

  /// NAS 远程照片目录（为空视为未配置，即使启用也不扫描）
  String nasRemoteDir;

  /// 是否启用 NAS 截图规则过滤（仅作用于 NAS 来源）
  bool nasFilterEnabled;

  /// NAS 过滤关键词（路径或文件名含关键词即排除，大小写不敏感）
  List<String> nasFilterKeywords;

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        city: j['city'] as String? ?? '北京',
        photoDir: j['photoDir'] as String? ?? '',
        serverPort: j['serverPort'] as int? ?? 8780,
        slideshowSeconds: j['slideshowSeconds'] as int? ?? 10,
        weatherRefreshMinutes: j['weatherRefreshMinutes'] as int? ?? 30,
        listenSeconds: j['listenSeconds'] as int? ?? 5,
        asrBaseUrl: j['asrBaseUrl'] as String? ?? 'https://api.openai.com/v1',
        asrApiKey: j['asrApiKey'] as String? ?? '',
        asrModel: j['asrModel'] as String? ?? 'whisper-1',
        ttsVoice: j['ttsVoice'] as String? ?? 'zh-CN-XiaoxiaoNeural',
        volume: (j['volume'] as num?)?.toDouble() ?? 0.8,
        wakeWordModelDir: j['wakeWordModelDir'] as String? ?? '',
        nasEnabled: j['nasEnabled'] as bool? ?? false,
        nasWebdavUrl: j['nasWebdavUrl'] as String? ?? 'http://192.168.1.22:5005',
        nasWebdavUser: j['nasWebdavUser'] as String? ?? '',
        nasWebdavPassword: j['nasWebdavPassword'] as String? ?? '',
        nasRemoteDir: j['nasRemoteDir'] as String? ?? '',
        nasFilterEnabled: j['nasFilterEnabled'] as bool? ?? true,
        nasFilterKeywords: (j['nasFilterKeywords'] as List?)?.cast<String>() ??
            const ['截图', 'screenshot', '屏幕快照', '收集'],
      );

  Map<String, dynamic> toJson() => {
        'city': city,
        'photoDir': photoDir,
        'serverPort': serverPort,
        'slideshowSeconds': slideshowSeconds,
        'weatherRefreshMinutes': weatherRefreshMinutes,
        'listenSeconds': listenSeconds,
        'asrBaseUrl': asrBaseUrl,
        'asrApiKey': asrApiKey,
        'asrModel': asrModel,
        'ttsVoice': ttsVoice,
        'volume': volume,
        'wakeWordModelDir': wakeWordModelDir,
        'nasEnabled': nasEnabled,
        'nasWebdavUrl': nasWebdavUrl,
        'nasWebdavUser': nasWebdavUser,
        'nasWebdavPassword': nasWebdavPassword,
        'nasRemoteDir': nasRemoteDir,
        'nasFilterEnabled': nasFilterEnabled,
        'nasFilterKeywords': nasFilterKeywords,
      };
}

/// 配置的加载与持久化，变更时通知。
class ConfigService extends ChangeNotifier {
  ConfigService(this.supportDir);

  /// 应用数据目录（path_provider 提供）
  final String supportDir;

  late AppConfig config = AppConfig();

  File get _file => File(p.join(supportDir, 'config.json'));

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        config = AppConfig.fromJson(
            jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {
      config = AppConfig();
    }
    _applyDefaults();
  }

  void _applyDefaults() {
    if (config.photoDir.isEmpty) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          supportDir;
      config.photoDir = p.join(home, 'Pictures');
    }
    if (config.wakeWordModelDir.isEmpty) {
      config.wakeWordModelDir = p.join(supportDir, 'kws-model');
    }
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()));
    notifyListeners();
  }
}
