import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'http_helper.dart';

/// WMO 天气码 → 中文描述
String weatherCodeText(int code) {
  if (code == 0) return '晴';
  if (code == 1) return '大部晴朗';
  if (code == 2) return '多云';
  if (code == 3) return '阴';
  if (code == 45 || code == 48) return '雾';
  if (code >= 51 && code <= 57) return '毛毛雨';
  if (code >= 61 && code <= 67) return code >= 65 ? '大雨' : '雨';
  if (code >= 71 && code <= 77) return '雪';
  if (code >= 80 && code <= 82) return '阵雨';
  if (code == 85 || code == 86) return '阵雪';
  if (code >= 95 && code <= 99) return '雷暴';
  return '未知';
}

class WeatherData {
  const WeatherData({
    required this.cityName,
    required this.temperature,
    required this.apparentTemperature,
    required this.humidity,
    required this.windSpeed,
    required this.weatherCode,
    required this.todayMax,
    required this.todayMin,
  });

  final String cityName;
  final double temperature;
  final double apparentTemperature;
  final int humidity;
  final double windSpeed;
  final int weatherCode;
  final double todayMax;
  final double todayMin;

  String get description => weatherCodeText(weatherCode);

  String get summary => '$cityName $description ${temperature.round()}°';
}

/// 解析 Open-Meteo forecast 响应（纯函数，便于测试）。
WeatherData weatherFromJson(String cityName, Map<String, dynamic> json) {
  final current = json['current'] as Map<String, dynamic>;
  final daily = json['daily'] as Map<String, dynamic>;
  return WeatherData(
    cityName: cityName,
    temperature: (current['temperature_2m'] as num).toDouble(),
    apparentTemperature: (current['apparent_temperature'] as num).toDouble(),
    humidity: (current['relative_humidity_2m'] as num).toInt(),
    windSpeed: (current['wind_speed_10m'] as num).toDouble(),
    weatherCode: (current['weather_code'] as num).toInt(),
    todayMax: ((daily['temperature_2m_max'] as List).first as num).toDouble(),
    todayMin: ((daily['temperature_2m_min'] as List).first as num).toDouble(),
  );
}

class WeatherService extends ChangeNotifier {
  WeatherService({required this.city, http.Client? client})
      : _client = client ?? createHttpClient();

  String city;
  final http.Client _client;
  Timer? _timer;

  WeatherData? data;
  String? error;

  double? _lat;
  double? _lon;
  String _resolvedName = '';

  void start({int refreshMinutes = 30}) {
    _timer?.cancel();
    unawaited(refresh());
    _timer = Timer.periodic(Duration(minutes: refreshMinutes), (_) => refresh());
  }

  Future<void> setCity(String newCity) async {
    if (newCity == city) return;
    city = newCity;
    _lat = _lon = null;
    await refresh();
  }

  Future<void> refresh() async {
    try {
      if (_lat == null || _lon == null) await _geocode();
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '$_lat',
        'longitude': '$_lon',
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m',
        'daily': 'temperature_2m_max,temperature_2m_min,weather_code',
        'timezone': 'auto',
        'forecast_days': '1',
      });
      final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      data = weatherFromJson(
          _resolvedName, jsonDecode(resp.body) as Map<String, dynamic>);
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> _geocode() async {
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': city,
      'count': '1',
      'language': 'zh',
      'format': 'json',
    });
    final resp = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final results =
        (jsonDecode(resp.body) as Map<String, dynamic>)['results'] as List? ??
            [];
    if (results.isEmpty) throw Exception('找不到城市: $city');
    final first = results.first as Map<String, dynamic>;
    _lat = (first['latitude'] as num).toDouble();
    _lon = (first['longitude'] as num).toDouble();
    _resolvedName = first['name'] as String? ?? city;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
