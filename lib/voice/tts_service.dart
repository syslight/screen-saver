import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

/// TTS 播报：优先 edge-tts（微软神经网络语音，免费），失败回退系统 TTS。
class TtsService {
  TtsService({this.voice = 'zh-CN-XiaoxiaoNeural', double volume = 0.8})
      : _volume = volume.clamp(0.0, 1.0).toDouble();

  String voice;

  // 懒加载：无 Flutter 绑定（单元测试）时也能构造 TtsService
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= AudioPlayer();

  double _volume;
  double get volume => _volume;

  set volume(double v) {
    _volume = v.clamp(0.0, 1.0);
    // 播放器还没创建（纯测试环境）时只记录值
    final p = _playerInstance;
    if (p != null) unawaited(p.setVolume(_volume));
  }

  static const _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromiumVersion = '131.0.2903.112';

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      final bytes = await _edgeTts(text).timeout(const Duration(seconds: 20));
      await _player.setVolume(_volume);
      await _player.stop();
      await _player.play(BytesSource(bytes));
    } catch (e) {
      debugPrint('edge-tts 失败，回退系统 TTS: $e');
      await _systemTts(text);
    }
  }

  /// edge-tts 的 Sec-MS-GEC 令牌：向下取整到 5 分钟的 Windows ticks + token 的 SHA256。
  @visibleForTesting
  static String secMsGec([int? windowsTicks]) {
    var ticks = windowsTicks ??
        ((DateTime.now().millisecondsSinceEpoch ~/ 1000 + 11644473600) *
            10000000);
    ticks -= ticks % 3000000000;
    return sha256
        .convert(utf8.encode('$ticks$_trustedClientToken'))
        .toString()
        .toUpperCase();
  }

  Future<Uint8List> _edgeTts(String text) async {
    final connectionId =
        DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(32, '0');
    final uri = Uri.parse(
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$_trustedClientToken'
        '&Sec-MS-GEC=${secMsGec()}'
        '&Sec-MS-GEC-Version=1-$_chromiumVersion'
        '&ConnectionId=$connectionId');

    final channel = IOWebSocketChannel.connect(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfndl',
    });

    String timestamp() => DateTime.now().toUtc().toIso8601String();

    channel.sink.add('X-Timestamp:${timestamp()}\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}');

    final ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'><voice name='$voice'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        '${_escapeXml(text)}</prosody></voice></speak>';
    channel.sink.add('X-RequestId:$connectionId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${timestamp()}\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml');

    final audio = BytesBuilder(copy: false);
    var done = false;
    await for (final message in channel.stream) {
      if (message is List<int>) {
        // 二进制帧：前 2 字节大端头部长度，头部含 Path:audio 时正文为音频
        if (message.length < 2) continue;
        final headerLen = (message[0] << 8) | message[1];
        final header = utf8.decode(message.sublist(2, 2 + headerLen));
        if (header.contains('Path:audio')) {
          audio.add(message.sublist(2 + headerLen));
        }
      } else if (message is String && message.contains('Path:turn.end')) {
        done = true;
        break;
      }
    }
    await channel.sink.close();
    if (!done || audio.isEmpty) {
      throw StateError('edge-tts 未返回音频');
    }
    return audio.takeBytes();
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll("'", '&apos;')
      .replaceAll('"', '&quot;');

  Future<void> _systemTts(String text) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('say', [text]);
      } else if (Platform.isWindows) {
        await Process.run('powershell', [
          '-Command',
          'Add-Type -AssemblyName System.Speech; '
              '(New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('
              '${jsonEncode(text)})',
        ]);
      } else {
        await Process.run('espeak-ng', ['-v', 'zh', text]);
      }
    } catch (e) {
      debugPrint('系统 TTS 也失败: $e');
    }
  }

  Future<void> stop() => _player.stop();

  Future<void> dispose() => _player.dispose();
}
