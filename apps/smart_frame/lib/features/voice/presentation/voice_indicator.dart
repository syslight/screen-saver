import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:smart_frame/features/voice/application/voice_provider.dart';

/// 右下角语音状态指示（compute 用 VoicePipeline，display 用 VoiceClient，都实现 VoiceProvider）。
class VoiceIndicator extends StatelessWidget {
  const VoiceIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceProvider>();
    final text = voice.statusMessage ?? voice.stateText;
    final (icon, color) = switch (text) {
      String s when s.contains('聆听') => (Icons.mic, Colors.redAccent),
      String s when s.contains('识别') => (
        Icons.psychology,
        Colors.lightBlueAccent,
      ),
      String s when s.contains('播报') => (Icons.volume_up, Colors.greenAccent),
      _ => (Icons.mic_none, Colors.white54),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(fontSize: 15, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
