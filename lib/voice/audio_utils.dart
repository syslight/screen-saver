import 'dart:math';
import 'dart:typed_data';

/// PCM 小端 int16 字节 → float32 采样（sherpa-onnx 输入格式）
Float32List pcmBytesToFloat32(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final count = bytes.length ~/ 2;
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// 原始 PCM（16bit 小端）加 WAV 头
Uint8List pcmToWav(List<Uint8List> chunks,
    {int sampleRate = 16000, int channels = 1}) {
  final dataSize = chunks.fold<int>(0, (sum, c) => sum + c.length);
  final byteRate = sampleRate * channels * 2;
  final header = ByteData(44);

  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  header.setUint32(4, 36 + dataSize, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  header.setUint32(40, dataSize, Endian.little);

  final out = Uint8List(44 + dataSize);
  out.setRange(0, 44, header.buffer.asUint8List());
  var offset = 44;
  for (final chunk in chunks) {
    out.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return out;
}

/// 生成一段正弦提示音（带淡入淡出防爆音），返回完整 WAV 字节。
Uint8List generateBeepWav(
    {double frequency = 880, int milliseconds = 150, int sampleRate = 16000}) {
  final count = sampleRate * milliseconds ~/ 1000;
  final pcm = Uint8List(count * 2);
  final view = ByteData.view(pcm.buffer);
  final fade = sampleRate ~/ 100; // 10ms 淡入淡出
  for (var i = 0; i < count; i++) {
    final envelope = min(1.0, min(i / fade, (count - i) / fade));
    final value =
        (sin(2 * pi * frequency * i / sampleRate) * envelope * 12000).round();
    view.setInt16(i * 2, value, Endian.little);
  }
  return pcmToWav([pcm], sampleRate: sampleRate);
}
