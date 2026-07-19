import 'dart:async';

import 'package:flutter/material.dart';

/// 大时钟 + 公历日期（右上角）。
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
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$h:$m',
            style: const TextStyle(
                fontSize: 96,
                fontWeight: FontWeight.w200,
                height: 1,
                color: Colors.white,
                shadows: _shadow)),
        Text('$s 秒  ${_now.month}月${_now.day}日',
            style: const TextStyle(
                fontSize: 22, color: Colors.white70, shadows: _shadow)),
      ],
    );
  }
}
