import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 应用配置。所有字段有默认值，零配置可启动。
class AppConfig {
  AppConfig({
    this.city = '广州',
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
    this.musicEnabled = true,
    this.musicMuted = false,
    this.musicVolume = 0.55,
    this.musicDir = '',
    this.musicOutputEnabled = true,
    this.musicQuietStartHour = 22,
    this.musicQuietEndHour = 8,
    this.wakeWordModelDir = '',
    this.nasEnabled = false,
    this.nasWebdavUrl = 'http://192.168.1.22:5005',
    this.nasWebdavUser = '',
    this.nasWebdavPassword = '',
    this.nasRemoteDir = '',
    this.nasFilterEnabled = true,
    this.nasFilterKeywords = const ['截图', 'screenshot', '屏幕快照', '收集'],
    this.dedupEnabled = true,
    this.dedupPHashThreshold = 5,
    this.nasFilterMinBytes = 30720,
    this.heicEnabled = true,
    this.vlmEnabled = false,
    this.vlmModel = 'minicpm-v',
    this.ollamaUrl = 'http://localhost:11434',
    this.serverRole = 'compute',
    this.computeNodeUrl = '',
    this.agentUrl = '',
    this.nodeId = '',
    this.roomId = '',
    this.deviceKey = '',
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

  /// 旧配置兼容字段；当前由 Home Agent 自动断句。
  int listenSeconds;

  /// 旧配置兼容字段；当前 ASR 只在 Home Agent 配置。
  String asrBaseUrl;
  String asrApiKey;
  String asrModel;

  /// edge-tts 语音名
  String ttsVoice;

  /// 播报音量 0..1
  double volume;

  /// 相册背景音乐开关、静音和独立音量。
  bool musicEnabled;
  bool musicMuted;
  double musicVolume;

  /// 用户音乐目录；为空时由 ConfigService 放到应用支持目录/music。
  String musicDir;

  /// 当前节点是否真正输出音乐。split 模式下 compute=false、display=true。
  bool musicOutputEnabled;

  /// 夜间自动静音区间（小时，起点包含、终点不包含）。
  int musicQuietStartHour;
  int musicQuietEndHour;

  /// 旧配置兼容字段；App 不加载 KWS 模型。
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

  /// 是否启用内容级去重（sha256 完全重复 + pHash 近似重复）
  bool dedupEnabled;

  /// pHash 海明距离 ≤ 此值视为近似重复（0-64，越小越严格）
  int dedupPHashThreshold;

  /// NAS 过滤：文件小于此字节数视为缩略图/图标，排除
  int nasFilterMinBytes;

  /// 是否支持 HEIC/HEIF（依赖系统 heif-convert，不可用时自动降级跳过）
  bool heicEnabled;

  /// 是否启用 VLM（ollama 视觉模型）打标签 + 非照片判定（重，默认关）
  bool vlmEnabled;

  /// ollama 视觉模型名（如 minicpm-v、llama3.2-vision、llava）
  String vlmModel;

  /// ollama API 地址
  String ollamaUrl;

  /// 节点角色：compute 是历史桌面兼容模式；display 为服务端驱动的薄客户端。
  String serverRole;

  /// 历史 compute/display 直连地址；新 display 不再使用。
  String computeNodeUrl;

  /// 独立家庭 Agent 地址与本设备节点凭据。展示端只连接该服务。
  /// home_agent 服务 URL 及服务端签发的节点凭据。
  String agentUrl;
  String nodeId;
  String roomId;
  String deviceKey;

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
    city: j['city'] as String? ?? '广州',
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
    musicEnabled: j['musicEnabled'] as bool? ?? true,
    musicMuted: j['musicMuted'] as bool? ?? false,
    musicVolume: (j['musicVolume'] as num?)?.toDouble() ?? 0.55,
    musicDir: j['musicDir'] as String? ?? '',
    musicOutputEnabled:
        j['musicOutputEnabled'] as bool? ?? _defaultMusicOutput(j),
    musicQuietStartHour: j['musicQuietStartHour'] as int? ?? 22,
    musicQuietEndHour: j['musicQuietEndHour'] as int? ?? 8,
    wakeWordModelDir: j['wakeWordModelDir'] as String? ?? '',
    nasEnabled: j['nasEnabled'] as bool? ?? false,
    nasWebdavUrl: j['nasWebdavUrl'] as String? ?? 'http://192.168.1.22:5005',
    nasWebdavUser: j['nasWebdavUser'] as String? ?? '',
    nasWebdavPassword: j['nasWebdavPassword'] as String? ?? '',
    nasRemoteDir: j['nasRemoteDir'] as String? ?? '',
    nasFilterEnabled: j['nasFilterEnabled'] as bool? ?? true,
    nasFilterKeywords:
        (j['nasFilterKeywords'] as List?)?.cast<String>() ??
        const ['截图', 'screenshot', '屏幕快照', '收集'],
    dedupEnabled: j['dedupEnabled'] as bool? ?? true,
    dedupPHashThreshold: j['dedupPHashThreshold'] as int? ?? 5,
    nasFilterMinBytes: j['nasFilterMinBytes'] as int? ?? 30720,
    heicEnabled: j['heicEnabled'] as bool? ?? true,
    vlmEnabled: j['vlmEnabled'] as bool? ?? false,
    vlmModel: j['vlmModel'] as String? ?? 'minicpm-v',
    ollamaUrl: j['ollamaUrl'] as String? ?? 'http://localhost:11434',
    serverRole: j['serverRole'] as String? ?? 'compute',
    computeNodeUrl: j['computeNodeUrl'] as String? ?? '',
    agentUrl: j['agentUrl'] as String? ?? '',
    nodeId: j['nodeId'] as String? ?? '',
    roomId: j['roomId'] as String? ?? '',
    deviceKey: j['deviceKey'] as String? ?? '',
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
    'musicEnabled': musicEnabled,
    'musicMuted': musicMuted,
    'musicVolume': musicVolume,
    'musicDir': musicDir,
    'musicOutputEnabled': musicOutputEnabled,
    'musicQuietStartHour': musicQuietStartHour,
    'musicQuietEndHour': musicQuietEndHour,
    'wakeWordModelDir': wakeWordModelDir,
    'nasEnabled': nasEnabled,
    'nasWebdavUrl': nasWebdavUrl,
    'nasWebdavUser': nasWebdavUser,
    'nasWebdavPassword': nasWebdavPassword,
    'nasRemoteDir': nasRemoteDir,
    'nasFilterEnabled': nasFilterEnabled,
    'nasFilterKeywords': nasFilterKeywords,
    'dedupEnabled': dedupEnabled,
    'dedupPHashThreshold': dedupPHashThreshold,
    'nasFilterMinBytes': nasFilterMinBytes,
    'heicEnabled': heicEnabled,
    'vlmEnabled': vlmEnabled,
    'vlmModel': vlmModel,
    'ollamaUrl': ollamaUrl,
    'serverRole': serverRole,
    'computeNodeUrl': computeNodeUrl,
    'agentUrl': agentUrl,
    'nodeId': nodeId,
    'roomId': roomId,
    'deviceKey': deviceKey,
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
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      config = AppConfig();
    }
    _applyDefaults();
  }

  void _applyDefaults() {
    if (config.photoDir.isEmpty) {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          supportDir;
      config.photoDir = p.join(home, 'Pictures');
    }
    if (config.wakeWordModelDir.isEmpty) {
      config.wakeWordModelDir = p.join(supportDir, 'kws-model');
    }
    if (config.musicDir.isEmpty) {
      config.musicDir = p.join(supportDir, 'music');
    }
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
    notifyListeners();
  }
}

bool _defaultMusicOutput(Map<String, dynamic> json) {
  if (!json.containsKey('serverRole')) return true;
  return json['serverRole'] == 'display';
}
