import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'server/control_server.dart';
import 'services/command_service.dart';
import 'services/nas_photo_source.dart';
import 'services/photo_service.dart';
import 'services/weather_service.dart';
import 'ui/dashboard_page.dart';
import 'voice/asr_client.dart';
import 'voice/tts_service.dart';
import 'voice/voice_pipeline.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configService = ConfigService(supportDir.path);
  await configService.load();
  final config = configService.config;

  // 相册目录不存在则创建
  await Directory(config.photoDir).create(recursive: true);

  // NAS 图源：按配置建客户端；缓存目录放在应用支持目录下
  final nasSource = NasPhotoSource()
    ..configure(
        url: config.nasWebdavUrl,
        user: config.nasWebdavUser,
        password: config.nasWebdavPassword,
        remoteDir: config.nasRemoteDir);
  final photos = PhotoService(config.photoDir,
      cacheDir: p.join(supportDir.path, 'nas-cache'));
  final weather = WeatherService(city: config.city);
  final tts = TtsService(voice: config.ttsVoice, volume: config.volume);
  final asr = AsrClient(
      baseUrl: config.asrBaseUrl,
      apiKey: config.asrApiKey,
      model: config.asrModel);
  final commands = CommandService(
      config: config, photos: photos, weather: weather, tts: tts);
  final voice = VoicePipeline(
    config: config,
    tts: tts,
    asr: asr,
    onText: commands.executeText,
  );
  commands.voiceStateText = () => voice.stateText;
  commands.onListenRequested = voice.triggerListen;

  // 各服务独立初始化，单个失败不影响整体
  await photos.init();
  // 应用 NAS 配置；内部按 nasEnabled 决定是否真连，失败静默降级
  await photos.applyNasConfig(config, nasSource);
  photos.startSlideshow(config.slideshowSeconds);
  weather.start(refreshMinutes: config.weatherRefreshMinutes);
  unawaited(voice.init());

  final indexHtml =
      await rootBundle.loadString('web_console/index.html');
  final server = ControlServer(
      port: config.serverPort,
      commands: commands,
      photos: photos,
      indexHtml: indexHtml);
  try {
    await server.start();
  } catch (e) {
    debugPrint('控制台服务器启动失败: $e');
  }

  unawaited(WakelockPlus.enable());
  unawaited(windowManager.setFullScreen(true));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: configService),
        ChangeNotifierProvider.value(value: photos),
        ChangeNotifierProvider.value(value: weather),
        ChangeNotifierProvider.value(value: voice),
        ChangeNotifierProvider.value(value: commands),
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
