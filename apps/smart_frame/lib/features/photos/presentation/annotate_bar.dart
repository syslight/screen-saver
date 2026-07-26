import 'package:flutter/material.dart';

/// 标注浮层：默认半透明（opacity 0.2，不抢眼、不影响看照片），鼠标 hover 时
/// 强化到完全不透明（200ms 动画）。点按钮标注当前照片为某类别 → 立即隐藏跳下一张。
///
/// 桌面用 MouseRegion hover；Android 无 hover 概念，可后续改长按触发或常显半透明。
class AnnotateBar extends StatefulWidget {
  const AnnotateBar({super.key, required this.onAnnotate});

  /// 接收类别 reason（duplicate/low_quality/ad/screenshot），由 dashboard 接到 annotate。
  final Future<void> Function(String reason) onAnnotate;

  @override
  State<AnnotateBar> createState() => _AnnotateBarState();
}

class _AnnotateBarState extends State<AnnotateBar> {
  bool _hover = false;

  static const _items = [
    ('重复', 'duplicate'),
    ('低画质', 'low_quality'),
    ('广告', 'ad'),
    ('截图', 'screenshot'),
  ];

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        opacity: _hover ? 1.0 : 0.2,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, reason) in _items)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton(
                    onPressed: () => widget.onAnnotate(reason),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
