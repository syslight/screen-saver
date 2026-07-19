import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../voice/voice_pipeline.dart';

/// 右下角语音状态指示。
class VoiceIndicator extends StatelessWidget {
  const VoiceIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoicePipeline>();
    final (icon, color) = switch (voice.state) {
      VoiceState.idle => (Icons.mic_none, Colors.white54),
      VoiceState.listening => (Icons.mic, Colors.redAccent),
      VoiceState.processing => (Icons.psychology, Colors.lightBlueAccent),
      VoiceState.speaking => (Icons.volume_up, Colors.greenAccent),
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
          Text(voice.statusMessage ?? voice.stateText,
              style: const TextStyle(fontSize: 15, color: Colors.white70)),
        ],
      ),
    );
  }
}
