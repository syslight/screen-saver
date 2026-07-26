import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/photo_index_service.dart';

/// 当前照片的家庭身份、时间、地点与第三人称故事。
/// 没有可靠信息的字段不显示，身份只显示家长确认过的关系标签。
class PhotoInfoWidget extends StatelessWidget {
  const PhotoInfoWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final description = context.select<PhotoIndexService, PhotoDescription?>(
      (s) => s.currentDescription,
    );
    if (description == null || description.isEmpty) {
      return const SizedBox.shrink();
    }
    final date = description.dateText;
    final location = description.location;
    final caption = description.caption;
    final identities = description.identities;
    final contentKey = [
      description.photoId,
      identities.join(','),
      date,
      location,
      caption,
    ].join('|');

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0.08),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey(contentKey),
        padding: const EdgeInsets.fromLTRB(28, 24, 30, 26),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.black.withValues(alpha: 0.72),
              Colors.black.withValues(alpha: 0.34),
            ],
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 28, spreadRadius: 2),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (identities.isNotEmpty)
              Text(
                identities.join('、'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                ),
              ),
            if (identities.isNotEmpty && (date != null || location != null))
              const SizedBox(height: 10),
            if (date != null || location != null)
              Wrap(
                spacing: 18,
                runSpacing: 8,
                children: [
                  if (location != null)
                    _InfoLine(icon: Icons.place_rounded, text: location),
                  if (date != null)
                    _InfoLine(icon: Icons.schedule_rounded, text: date),
                ],
              ),
            if (caption != null) ...[
              const SizedBox(height: 14),
              Text(
                caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                  letterSpacing: 0.4,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 10)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 21, color: Colors.white70),
        const SizedBox(width: 7),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 20,
            shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
          ),
        ),
      ],
    );
  }
}
