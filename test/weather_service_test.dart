import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/services/weather_service.dart';

void main() {
  group('weatherCodeText', () {
    test('常见天气码', () {
      expect(weatherCodeText(0), '晴');
      expect(weatherCodeText(2), '多云');
      expect(weatherCodeText(3), '阴');
      expect(weatherCodeText(45), '雾');
      expect(weatherCodeText(61), '雨');
      expect(weatherCodeText(95), '雷暴');
      expect(weatherCodeText(999), '未知');
    });
  });

  group('weatherFromJson', () {
    test('解析 Open-Meteo 响应', () {
      final json = {
        'current': {
          'temperature_2m': 26.4,
          'relative_humidity_2m': 55,
          'apparent_temperature': 27.1,
          'weather_code': 2,
          'wind_speed_10m': 12.3,
        },
        'daily': {
          'temperature_2m_max': [31.2],
          'temperature_2m_min': [21.8],
          'weather_code': [2],
        },
      };
      final d = weatherFromJson('北京', json);
      expect(d.cityName, '北京');
      expect(d.temperature, 26.4);
      expect(d.humidity, 55);
      expect(d.weatherCode, 2);
      expect(d.todayMax, 31.2);
      expect(d.todayMin, 21.8);
      expect(d.description, '多云');
      expect(d.summary, '北京 多云 26°');
    });
  });
}
