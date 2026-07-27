import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/voice/application/streaming_pcm_player.dart';

void main() {
  test('PCM 流回退 WAV 头包含正确格式和数据长度', () {
    final wav = pcmToWavBytes(
      Uint8List.fromList([1, 0, 2, 0]),
      sampleRate: 24000,
    );
    final header = ByteData.sublistView(wav);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 24000);
    expect(header.getUint32(40, Endian.little), 4);
    expect(wav.sublist(44), [1, 0, 2, 0]);
  });

  test('Linux 软件音量按有符号 PCM16 缩放', () {
    final input = Uint8List(4);
    final data = ByteData.sublistView(input);
    data.setInt16(0, 20000, Endian.little);
    data.setInt16(2, -20000, Endian.little);

    final scaled = ByteData.sublistView(scalePcm16(input, 0.5));

    expect(scaled.getInt16(0, Endian.little), 10000);
    expect(scaled.getInt16(2, Endian.little), -10000);
  });
}
