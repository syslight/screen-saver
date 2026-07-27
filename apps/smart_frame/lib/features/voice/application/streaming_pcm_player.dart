import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

enum _PcmBackend { android, linux, buffered }

/// Low-latency PCM output for the display platforms, with a portable WAV fallback.
class StreamingPcmPlayer {
  static const _channel = MethodChannel('smart_frame/pcm_stream');

  final AudioPlayer _fallbackPlayer = AudioPlayer();
  _PcmBackend _backend = _PcmBackend.buffered;
  Process? _linuxPlayer;
  BytesBuilder _buffer = BytesBuilder(copy: false);
  int _sampleRate = 24000;
  int _channels = 1;
  double _volume = 1;
  bool _active = false;

  Future<void> start({
    required int sampleRate,
    required int channels,
    required double volume,
  }) async {
    await cancel();
    _sampleRate = sampleRate;
    _channels = channels;
    _volume = volume.clamp(0, 1);
    _buffer = BytesBuilder(copy: false);
    _active = true;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('start', {
          'sampleRate': sampleRate,
          'channels': channels,
          'volume': _volume,
        });
        _backend = _PcmBackend.android;
        return;
      } on PlatformException {
        _backend = _PcmBackend.buffered;
        return;
      } on MissingPluginException {
        _backend = _PcmBackend.buffered;
        return;
      }
    }
    if (Platform.isLinux) {
      try {
        _linuxPlayer = await Process.start('aplay', [
          '-q',
          '-t',
          'raw',
          '-f',
          'S16_LE',
          '-r',
          '$sampleRate',
          '-c',
          '$channels',
        ]);
        _backend = _PcmBackend.linux;
        return;
      } on ProcessException {
        _backend = _PcmBackend.buffered;
        return;
      }
    }
    _backend = _PcmBackend.buffered;
  }

  Future<void> write(Uint8List pcm) async {
    if (!_active || pcm.isEmpty) return;
    switch (_backend) {
      case _PcmBackend.android:
        await _channel.invokeMethod<void>('write', pcm);
      case _PcmBackend.linux:
        final output = _volume >= 0.999 ? pcm : scalePcm16(pcm, _volume);
        _linuxPlayer?.stdin.add(output);
        await _linuxPlayer?.stdin.flush();
      case _PcmBackend.buffered:
        _buffer.add(pcm);
    }
  }

  Future<void> finish() async {
    if (!_active) return;
    _active = false;
    switch (_backend) {
      case _PcmBackend.android:
        await _channel.invokeMethod<void>('finish');
      case _PcmBackend.linux:
        final process = _linuxPlayer;
        _linuxPlayer = null;
        await process?.stdin.close();
        await process?.exitCode;
      case _PcmBackend.buffered:
        final bytes = _buffer.takeBytes();
        if (bytes.isEmpty) return;
        await _fallbackPlayer.setVolume(_volume);
        await _fallbackPlayer.play(
          BytesSource(
            pcmToWavBytes(bytes, sampleRate: _sampleRate, channels: _channels),
          ),
        );
        await _fallbackPlayer.onPlayerComplete.first.timeout(
          const Duration(seconds: 90),
        );
    }
  }

  Future<void> cancel() async {
    if (!_active && _linuxPlayer == null) return;
    _active = false;
    _buffer = BytesBuilder(copy: false);
    switch (_backend) {
      case _PcmBackend.android:
        try {
          await _channel.invokeMethod<void>('cancel');
        } on PlatformException {
          // The platform stream may already have been released.
        } on MissingPluginException {
          // Tests and unsupported platforms use the buffered backend.
        }
      case _PcmBackend.linux:
        final process = _linuxPlayer;
        _linuxPlayer = null;
        process?.kill();
      case _PcmBackend.buffered:
        await _fallbackPlayer.stop();
    }
  }

  Future<void> dispose() async {
    await cancel();
    await _fallbackPlayer.dispose();
  }
}

Uint8List scalePcm16(Uint8List pcm, double volume) {
  final result = Uint8List.fromList(pcm);
  final data = ByteData.sublistView(result);
  for (var offset = 0; offset + 1 < result.length; offset += 2) {
    final sample = data.getInt16(offset, Endian.little);
    data.setInt16(
      offset,
      (sample * volume).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return result;
}

Uint8List pcmToWavBytes(
  Uint8List pcm, {
  required int sampleRate,
  int channels = 1,
}) {
  const sampleWidth = 2;
  final byteRate = sampleRate * channels * sampleWidth;
  final blockAlign = channels * sampleWidth;
  final result = Uint8List(44 + pcm.length);
  final header = ByteData.sublistView(result);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      result[offset + index] = value.codeUnitAt(index);
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, sampleWidth * 8, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  result.setRange(44, result.length, pcm);
  return result;
}
