import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/calendar_service.dart';

/// 日历小组件：农历、干支生肖、节气、节日。
class CalendarWidget extends StatefulWidget {
  const CalendarWidget({super.key});

  @override
  State<CalendarWidget> createState() => _CalendarWidgetState();
}

class _CalendarWidgetState extends State<CalendarWidget> {
  late Timer _timer;
  CalendarInfo _info = calendarInfoFor(DateTime.now());

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() => _info = calendarInfoFor(DateTime.now()));
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  static const _shadow = [Shadow(blurRadius: 10, color: Colors.black87)];

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '农历${_info.lunarDate}',
      '${_info.ganzhiYear}年 属${_info.shengxiao}',
      _info.week,
      if (_info.jieqi != null) _info.jieqi!,
      ..._info.festivals,
    ];
    return Text(
      parts.join('  ·  '),
      style: const TextStyle(
        fontSize: 18,
        height: 1.4,
        color: Colors.white70,
        shadows: _shadow,
      ),
    );
  }
}
