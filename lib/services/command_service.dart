import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../server/protocol.dart';
import '../services/calendar_service.dart';
import '../services/photo_service.dart';
import '../services/weather_service.dart';
import '../voice/intent_parser.dart';
import '../voice/tts_service.dart';

/// 统一指令总线：手机 WS 指令、语音意图、键盘快捷键都汇聚到这里，
/// 执行后通过 [onEvent]/[onStateChanged] 通知服务器广播给所有手机。
class CommandService extends ChangeNotifier {
  CommandService({
    required this.config,
    required this.photos,
    required this.weather,
    required this.tts,
  }) {
    // 监听相册变化：仅当 NAS 状态文案变化时才广播给手机端
    // （定时轮播 nasStatus 不变、不广播，零副作用；顺带修复手机端
    //  看不到 NAS 连接状态实时更新的隐患——见 web 端 POST /api/config）。
    _lastNasStatus = photos.nasStatus;
    photos.addListener(_onPhotosChanged);
  }

  final AppConfig config;
  final PhotoService photos;
  final WeatherService weather;
  final TtsService tts;

  /// 事件消息（给控制台日志）
  void Function(String message)? onEvent;

  /// 状态变化（触发服务器广播最新状态）
  VoidCallback? onStateChanged;

  /// 手机端"按住说话"按钮请求聆听（由 main 接到 VoicePipeline）
  VoidCallback? onListenRequested;

  /// 由 main 注入：语音状态文本（用于状态快照）
  String Function()? voiceStateText;

  bool showQrRequested = false;

  /// 上一次广播时的 NAS 状态文案，用于检测变化。
  String _lastNasStatus = '';

  void dismissQr() {
    showQrRequested = false;
    notifyListeners();
  }

  /// PhotoService 变化时，仅在 NAS 状态文案变化时触发一次广播。
  void _onPhotosChanged() {
    final s = photos.nasStatus;
    if (s != _lastNasStatus) {
      _lastNasStatus = s;
      onStateChanged?.call();
    }
  }

  @override
  void dispose() {
    photos.removeListener(_onPhotosChanged);
    super.dispose();
  }

  Future<String> executeCommand(ConsoleCommand cmd) async {
    String message;
    switch (cmd.action) {
      case 'next_photo':
        photos.next();
        message = '已切到下一张';
      case 'prev_photo':
        photos.prev();
        message = '已切到上一张';
      case 'refresh_weather':
        await weather.refresh();
        message = weather.error == null ? '天气已刷新' : '天气刷新失败';
      case 'set_volume':
        tts.volume = (cmd.value ?? tts.volume).clamp(0.0, 1.0);
        config.volume = tts.volume;
        message = '音量 ${(tts.volume * 100).round()}%';
      case 'announce':
        final text = cmd.text ?? '';
        if (text.isEmpty) {
          message = '播报内容为空';
        } else {
          await tts.speak(text);
          message = '播报：$text';
        }
      case 'text_command':
        message = await executeText(cmd.text ?? '');
      case 'show_qr':
        showQrRequested = true;
        notifyListeners();
        message = '二维码已显示';
      case 'hide_qr':
        showQrRequested = false;
        notifyListeners();
        message = '二维码已隐藏';
      case 'listen':
        onListenRequested?.call();
        message = '开始聆听';
      default:
        message = '未知指令: ${cmd.action}';
    }
    onEvent?.call(message);
    onStateChanged?.call();
    return message;
  }

  /// 文字指令入口（手机端输入框、语音 ASR 结果共用）
  Future<String> executeText(String text) => executeIntent(parseIntent(text));

  Future<String> executeIntent(Intent intent) async {
    final now = DateTime.now();
    String reply;
    switch (intent.type) {
      case IntentType.weather:
        final d = weather.data;
        reply = d == null
            ? '天气数据还没准备好，请稍后再试'
            : '${d.cityName}现在${d.description}，${d.temperature.round()}度，'
                '体感${d.apparentTemperature.round()}度，湿度${d.humidity}%。'
                '今天最高${d.todayMax.round()}度，最低${d.todayMin.round()}度。';
      case IntentType.time:
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        reply = '现在时间是 $h 点 $m 分。';
      case IntentType.date:
        final info = calendarInfoFor(now);
        reply = '今天是${now.month}月${now.day}日，${info.week}。'
            '${info.festivals.isNotEmpty ? '今天是${info.festivals.join('、')}。' : ''}';
      case IntentType.lunar:
        final info = calendarInfoFor(now);
        reply = '今天是农历${info.lunarDate}，${info.ganzhiYear}年，生肖属${info.shengxiao}。'
            '${info.jieqi != null ? '今天是${info.jieqi}。' : ''}';
      case IntentType.nextPhoto:
        photos.next();
        reply = '好的，下一张。';
      case IntentType.prevPhoto:
        photos.prev();
        reply = '好的，上一张。';
      case IntentType.volumeUp:
        tts.volume = (tts.volume + 0.1).clamp(0.0, 1.0);
        config.volume = tts.volume;
        reply = '音量调到 ${(tts.volume * 100).round()}%。';
      case IntentType.volumeDown:
        tts.volume = (tts.volume - 0.1).clamp(0.0, 1.0);
        config.volume = tts.volume;
        reply = '音量调到 ${(tts.volume * 100).round()}%。';
      case IntentType.setVolume:
        tts.volume = (intent.value ?? tts.volume).clamp(0.0, 1.0);
        config.volume = tts.volume;
        reply = '音量调到 ${(tts.volume * 100).round()}%。';
      case IntentType.announce:
        await tts.speak(intent.text ?? '');
        reply = '好的。';
      case IntentType.showQr:
        showQrRequested = true;
        notifyListeners();
        reply = '二维码已显示在屏幕上。';
      case IntentType.help:
        reply = '我可以播报天气、时间和农历，可以切换照片、调节音量。'
            '你也可以用手机给我传照片、让我传话。';
      case IntentType.unknown:
        reply = '没听懂。你可以问天气、问日期，或者说下一张、音量大一点。';
    }
    onStateChanged?.call();
    return reply;
  }

  Map<String, Object?> currentState() => {
        'photo': photos.currentName,
        'photoCount': photos.photos.length,
        'weather': weather.data?.summary ??
            (weather.error != null ? '获取失败' : '加载中…'),
        'voice': voiceStateText?.call() ?? '-',
        'volume': tts.volume,
        'nas': photos.nasStatus,
      };
}
