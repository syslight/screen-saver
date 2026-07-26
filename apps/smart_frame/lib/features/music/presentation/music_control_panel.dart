import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:smart_frame/features/music/application/music_service.dart';

class MusicControlPanel extends StatelessWidget {
  const MusicControlPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicService>();
    final compact = MediaQuery.sizeOf(context).width < 900;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: music.enabled ? 1 : 0.72,
      child: Container(
        width: compact ? 330 : 390,
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
          color: Colors.black.withValues(alpha: 0.52),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 18)],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: music.enabled ? '暂停背景音乐' : '播放背景音乐',
              onPressed: () => unawaited(music.setEnabled(!music.enabled)),
              icon: Icon(
                music.enabled
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                size: 34,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    music.quietHoursActive ? '夜间静音' : music.currentMood.label,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    music.currentTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: music.muted ? '打开音乐声音' : '静音音乐',
              onPressed: () => unawaited(music.setMuted(!music.muted)),
              icon: Icon(
                music.muted || music.quietHoursActive
                    ? Icons.volume_off_rounded
                    : Icons.volume_down_rounded,
              ),
            ),
            SizedBox(
              width: compact ? 74 : 100,
              child: Slider(
                value: music.volume,
                onChanged: music.enabled
                    ? (value) => unawaited(
                        music.setVolume(value, persist: false, forward: false),
                      )
                    : null,
                onChangeEnd: music.enabled
                    ? (value) => unawaited(music.setVolume(value))
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
