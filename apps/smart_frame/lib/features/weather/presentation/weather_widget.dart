import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:smart_frame/features/weather/application/weather_service.dart';

IconData weatherCodeIcon(int code) {
  if (code == 0 || code == 1) return Icons.wb_sunny;
  if (code == 2) return Icons.cloud_queue;
  if (code == 3) return Icons.cloud;
  if (code == 45 || code == 48) return Icons.foggy;
  if (code >= 51 && code <= 67) return Icons.umbrella;
  if (code >= 71 && code <= 77) return Icons.ac_unit;
  if (code >= 80 && code <= 82) return Icons.umbrella;
  if (code == 85 || code == 86) return Icons.ac_unit;
  if (code >= 95) return Icons.thunderstorm;
  return Icons.help_outline;
}

/// 紧凑天气小组件（由主页统一放在左上角）。
class WeatherWidget extends StatelessWidget {
  const WeatherWidget({super.key});

  static const _shadow = [Shadow(blurRadius: 10, color: Colors.black87)];

  @override
  Widget build(BuildContext context) {
    final weather = context.watch<WeatherService>();
    final d = weather.data;
    if (d == null) {
      return Text(
        weather.error != null ? '天气获取失败' : '天气加载中…',
        style: const TextStyle(
          fontSize: 18,
          color: Colors.white70,
          shadows: _shadow,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              weatherCodeIcon(d.weatherCode),
              size: 36,
              color: Colors.white,
              shadows: _shadow,
            ),
            const SizedBox(width: 10),
            Text(
              '${d.temperature.round()}°',
              style: const TextStyle(
                fontSize: 46,
                fontWeight: FontWeight.w300,
                height: 1,
                color: Colors.white,
                shadows: _shadow,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${d.cityName} · ${d.description} · '
          '${d.todayMin.round()}°/${d.todayMax.round()}° · 湿度${d.humidity}%',
          style: const TextStyle(
            fontSize: 18,
            color: Colors.white70,
            shadows: _shadow,
          ),
        ),
      ],
    );
  }
}
