import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'server/control_server.dart';
import 'services/command_service.dart';
import 'services/http_photo_source.dart';
import 'services/photo_index_service.dart';
import 'services/nas_photo_source.dart';
import 'services/photo_service.dart';
import 'services/weather_service.dart';
import 'ui/dashboard_page.dart';
import 'ui/android_setup_page.dart';
import 'voice/asr_client.dart';
import 'voice/tts_service.dart';
import 'voice/voice_client.dart';
import 'voice/voice_pipeline.dart';
import 'voice/voice_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) await windowManager.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configService = ConfigService(supportDir.path);
  await configService.load();
  if (Platform.isAndroid) {
    configService.config.serverRole = 'display';
    if (!validComputeNodeUrl(configService.config.computeNodeUrl)) {
      runApp(
        AndroidSetupApp(
          configService: configService,
          onConfigured: () => _startSmartFrame(configService),
        ),
      );
      return;
    }
  }
  await _startSmartFrame(configService);
}

Future<void> _startSmartFrame(ConfigService configService) async {
  final config = configService.config;

  // 相册目录不存在则创建
  await Directory(config.photoDir).create(recursive: true);

  // 检测系统 heif-convert（HEIC 解码依赖；Android 无此工具，display 照片已由计算端转 jpg）
  if (!Platform.isAndroid) await PhotoService.detectHeifConvert();
  // 节点角色：compute 直连 NAS + 本地 SQLite；display 从 computeNodeUrl 拉照片/索引
  final isDisplay = config.serverRole == 'display';
  // NAS 图源：按配置建客户端；缓存目录放在应用支持目录下
  final NasSource nasSource = isDisplay
      ? HttpPhotoSource(config.computeNodeUrl)
      : (NasPhotoSource()..configure(
          url: config.nasWebdavUrl,
          user: config.nasWebdavUser,
          password: config.nasWebdavPassword,
          remoteDir: config.nasRemoteDir,
        ));
  final photos = PhotoService(
    config.photoDir,
    cacheDir: p.join(configService.supportDir, 'nas-cache'),
  )..heicEnabled = config.heicEnabled;
  final weather = WeatherService(city: config.city);
  final tts = TtsService(voice: config.ttsVoice, volume: config.volume);
  final asr = AsrClient(
    baseUrl: config.asrBaseUrl,
    apiKey: config.asrApiKey,
    model: config.asrModel,
  );
  final commands = CommandService(
    config: config,
    photos: photos,
    weather: weather,
    tts: tts,
  );
  // C/S：compute 跑 VoicePipeline（KWS/ASR/TTS，external WS 服务 ARM）；
  // display 用 VoiceClient（record→WS，收 state/TTS→播），不跑模型。
  final StreamController<Uint8List>? ttsController;
  final VoicePipeline? voice;
  final VoiceProvider voiceProvider;
  if (isDisplay) {
    voice = null;
    ttsController = null;
    voiceProvider = VoiceClient(config.computeNodeUrl);
  } else {
    voice = VoicePipeline(
      config: config,
      tts: tts,
      asr: asr,
      onText: commands.executeText,
    );
    ttsController = StreamController<Uint8List>();
    voice.startExternal(ttsController);
    voiceProvider = voice;
  }
  commands.voiceStateText = () => voiceProvider.stateText;
  commands.onListenRequested = voiceProvider.triggerListen;

  // 各服务独立初始化，单个失败不影响整体
  await photos.init();
  // 应用 NAS 配置；内部按 nasEnabled 决定是否真连，失败静默降级
  await photos.applyNasConfig(config, nasSource, forceEnabled: isDisplay);
  photos.startSlideshow(config.slideshowSeconds);
  weather.start(refreshMinutes: config.weatherRefreshMinutes);
  if (isDisplay) {
    unawaited((voiceProvider as VoiceClient).init());
  } else {
    unawaited(voice!.init());
  }

  // 照片索引/去重服务：compute 读本地 SQLite（守护进程写），display 走 HTTP
  final photoIndexBackend = isDisplay
      ? HttpIndexBackend(config.computeNodeUrl)
      : SqliteIndexBackend(p.join(configService.supportDir, 'photo_index.db'));
  final photoIndex = PhotoIndexService(photos, photoIndexBackend);
  await photoIndex.init(config);
  commands.photoIndex = photoIndex; // 筛选播放（语音/控制台「放猫的」）

  final indexHtml = await rootBundle.loadString('web_console/index.html');
  final server = ControlServer(
    port: config.serverPort,
    commands: commands,
    photos: photos,
    indexHtml: indexHtml,
    configService: configService,
    nas: nasSource,
    photoIndex: photoIndex,
    voice: isDisplay ? null : voice,
    ttsController: ttsController,
  );
  if (!isDisplay) {
    try {
      await server.start();
    } catch (e) {
      debugPrint('控制台服务器启动失败: $e');
    }
  }

  unawaited(WakelockPlus.enable());
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } else {
    unawaited(windowManager.setFullScreen(true));
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: configService),
        ChangeNotifierProvider.value(value: photos),
        ChangeNotifierProvider.value(value: weather),
        ChangeNotifierProvider.value(value: voiceProvider),
        ChangeNotifierProvider.value(value: commands),
        ChangeNotifierProvider.value(value: photoIndex),
        Provider.value(value: tts),
        Provider.value(value: asr),
        Provider.value(value: nasSource),
        Provider.value(value: server),
      ],
      child: const SmartFrameApp(),
    ),
  );
}

class SmartFrameApp extends StatelessWidget {
  const SmartFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能屏',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const DashboardPage(),
    );
  }
}
