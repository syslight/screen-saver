import 'dart:async';

import 'package:flutter/material.dart';

/// 大时钟 + 公历日期（由主页统一放在左上角）。
class ClockWidget extends StatefulWidget {
  const ClockWidget({super.key});

  @override
  State<ClockWidget> createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<ClockWidget> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  static const _shadow = [Shadow(blurRadius: 12, color: Colors.black87)];

  @override
  Widget build(BuildContext context) {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    final s = _now.second.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$h:$m',
          style: const TextStyle(
            fontSize: 82,
            fontWeight: FontWeight.w300,
            height: 1,
            color: Colors.white,
            shadows: _shadow,
          ),
        ),
        Text(
          '${_now.month}月${_now.day}日  $s 秒',
          style: const TextStyle(
            fontSize: 20,
            color: Colors.white70,
            shadows: _shadow,
          ),
        ),
      ],
    );
  }
}
