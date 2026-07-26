import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:smart_frame/features/voice/application/audio_utils.dart';

/// sherpa-onnx KWS 唤醒词检测。模型文件缺失或加载失败时退化为不可用，
/// 语音交互仍可通过按键/手机按钮手动触发。
class WakeWordService {
  WakeWordService({required this.onWake});

  final VoidCallback onWake;

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;

  bool available = false;

  /// KWS 模型下载地址（中文关键词模型，含 keywords.txt）。
  static const modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/'
      'download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2';

  bool init(String modelDir) {
    try {
      final dir = Directory(modelDir);
      if (!dir.existsSync()) return false;
      final encoder = _findModelFile(dir, 'encoder');
      final decoder = _findModelFile(dir, 'decoder');
      final joiner = _findModelFile(dir, 'joiner');
      final tokens = File(p.join(modelDir, 'tokens.txt'));
      final keywords = File(p.join(modelDir, 'keywords.txt'));
      if (encoder == null ||
          decoder == null ||
          joiner == null ||
          !tokens.existsSync() ||
          !keywords.existsSync()) {
        return false;
      }

      sherpa.initBindings();
      final config = sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens.path,
          numThreads: 2,
          debug: false,
        ),
        keywordsFile: keywords.path,
        maxActivePaths: 4,
        keywordsThreshold: 0.25,
      );
      _spotter = sherpa.KeywordSpotter(config);
      _stream = _spotter!.createStream();
      available = true;
    } catch (e) {
      debugPrint('唤醒词初始化失败: $e');
      available = false;
    }
    return available;
  }

  /// 优先选非 int8 模型（精度更好），其次 int8。
  static String? _findModelFile(Directory dir, String prefix) {
    String? fallback;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix) || !name.endsWith('.onnx')) continue;
      if (!name.contains('int8')) return entity.path;
      fallback = entity.path;
    }
    return fallback;
  }

  /// 喂入一段 16kHz 单声道 PCM；检测到唤醒词时回调 [onWake]。
  void feed(Uint8List pcmChunk) {
    if (!available) return;
    try {
      _stream!.acceptWaveform(
        samples: pcmBytesToFloat32(pcmChunk),
        sampleRate: 16000,
      );
      while (_spotter!.isReady(_stream!)) {
        _spotter!.decode(_stream!);
      }
      if (_spotter!.getResult(_stream!).keyword.isNotEmpty) {
        _spotter!.reset(_stream!);
        onWake();
      }
    } catch (e) {
      debugPrint('唤醒词检测异常: $e');
    }
  }

  void reset() {
    if (available) _spotter?.reset(_stream!);
  }

  void dispose() {
    _stream?.free();
    _spotter?.free();
    available = false;
  }
}

/// 确保 KWS 模型存在；缺失时后台下载解压（失败返回 false，不影响其他功能）。
Future<bool> ensureKwsModel(String modelDir) async {
  if (File(p.join(modelDir, 'tokens.txt')).existsSync()) return true;
  try {
    await Directory(modelDir).create(recursive: true);
    final archive = File(p.join(modelDir, 'kws-model.tar.bz2'));
    final response = await http.Client()
        .send(http.Request('GET', Uri.parse(WakeWordService.modelUrl)))
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) return false;
    final sink = archive.openWrite();
    await response.stream.pipe(sink);
    await sink.close();
    final result = await Process.run('tar', [
      '-xf',
      archive.path,
      '-C',
      modelDir,
      '--strip-components=1',
    ]);
    await archive.delete();
    if (result.exitCode != 0) return false;
    return File(p.join(modelDir, 'tokens.txt')).existsSync();
  } catch (e) {
    debugPrint('KWS 模型下载失败: $e');
    return false;
  }
}
