// 本地意图解析：把语音识别或手机输入的文字映射为具体指令。
// 纯 Dart，无外部依赖，便于测试。

enum IntentType {
  weather,
  time,
  date,
  lunar,
  nextPhoto,
  prevPhoto,
  volumeUp,
  volumeDown,
  setVolume,
  announce,
  showQr,
  help,
  unknown,
}

class Intent {
  const Intent(this.type, {this.text, this.value});

  final IntentType type;

  /// announce 的文字内容
  final String? text;

  /// setVolume 的目标音量 0..1
  final double? value;
}

Intent parseIntent(String raw) {
  final text = raw.trim().replaceAll(RegExp(r'[，。！？!?,.\s]+$'), '');
  if (text.isEmpty) return const Intent(IntentType.unknown);

  // 播报：以"播报"/"说"开头
  for (final prefix in ['播报', '说']) {
    if (text.startsWith(prefix) && text.length > prefix.length) {
      final rest =
          text.substring(prefix.length).replaceFirst(RegExp(r'^[：:，,\s]+'), '');
      if (rest.isNotEmpty) return Intent(IntentType.announce, text: rest);
    }
  }

  if (text.contains('天气')) return const Intent(IntentType.weather);
  if (text.contains('农历') || text.contains('阴历')) {
    return const Intent(IntentType.lunar);
  }
  if (text.contains('几点') || text.contains('时间')) {
    return const Intent(IntentType.time);
  }
  if (text.contains('几号') ||
      text.contains('日期') ||
      text.contains('星期') ||
      text.contains('什么日子')) {
    return const Intent(IntentType.date);
  }

  if (text.contains('上一张') || text.contains('前一张')) {
    return const Intent(IntentType.prevPhoto);
  }
  if (text.contains('下一张') || text.contains('换一张') || text.contains('换一个')) {
    return const Intent(IntentType.nextPhoto);
  }

  // 音量：优先匹配带数字的
  final volMatch = RegExp(r'音量[^\d]{0,4}(\d{1,3})').firstMatch(text);
  if (volMatch != null) {
    final v = int.parse(volMatch.group(1)!);
    final value = v > 1 ? v / 100.0 : v.toDouble();
    return Intent(IntentType.setVolume, value: value.clamp(0.0, 1.0));
  }
  if (text.contains('音量')) {
    if (text.contains('大') || text.contains('高') || text.contains('加')) {
      return const Intent(IntentType.volumeUp);
    }
    if (text.contains('小') || text.contains('低') || text.contains('减')) {
      return const Intent(IntentType.volumeDown);
    }
  }

  if (text.contains('二维码')) return const Intent(IntentType.showQr);
  if (text.contains('帮助') ||
      text.contains('会什么') ||
      text.contains('能做什么') ||
      text.contains('会做什么')) {
    return const Intent(IntentType.help);
  }

  return const Intent(IntentType.unknown);
}
