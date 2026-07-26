import 'dart:convert';

/// 手机控制台发来的指令。
class ConsoleCommand {
  ConsoleCommand({required this.action, this.text, this.value});

  /// next_photo / prev_photo / refresh_weather / set_volume /
  /// set_music_enabled / set_music_muted / set_music_volume / announce /
  /// text_command / show_qr / hide_qr / listen
  final String action;
  final String? text;
  final double? value;

  factory ConsoleCommand.fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'command') {
      throw const FormatException('not a command message');
    }
    final action = json['action'];
    if (action is! String || action.isEmpty) {
      throw const FormatException('missing action');
    }
    return ConsoleCommand(
      action: action,
      text: json['text'] is String ? json['text'] as String : null,
      value: json['value'] is num ? (json['value'] as num).toDouble() : null,
    );
  }
}

/// 解析一条 WebSocket 文本消息，非法时抛 [FormatException]。
ConsoleCommand decodeCommand(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('message is not an object');
  }
  return ConsoleCommand.fromJson(decoded);
}

/// 广播给所有手机端的状态快照。
String encodeState(Map<String, Object?> fields) =>
    jsonEncode({'type': 'state', ...fields});

/// 广播给所有手机端的事件消息。
String encodeEvent(String message) =>
    jsonEncode({'type': 'event', 'message': message});
