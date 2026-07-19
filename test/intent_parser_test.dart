import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/voice/intent_parser.dart';

void main() {
  group('parseIntent', () {
    test('天气', () {
      expect(parseIntent('今天天气怎么样').type, IntentType.weather);
      expect(parseIntent('北京天气').type, IntentType.weather);
    });

    test('时间', () {
      expect(parseIntent('现在几点了').type, IntentType.time);
      expect(parseIntent('现在时间').type, IntentType.time);
    });

    test('日期', () {
      expect(parseIntent('今天几号').type, IntentType.date);
      expect(parseIntent('今天星期几').type, IntentType.date);
      expect(parseIntent('今天是什么日子').type, IntentType.date);
    });

    test('农历', () {
      expect(parseIntent('今天农历是多少').type, IntentType.lunar);
      expect(parseIntent('阴历几号').type, IntentType.lunar);
    });

    test('照片切换', () {
      expect(parseIntent('下一张照片').type, IntentType.nextPhoto);
      expect(parseIntent('换一张').type, IntentType.nextPhoto);
      expect(parseIntent('上一张').type, IntentType.prevPhoto);
    });

    test('音量', () {
      expect(parseIntent('音量大一点').type, IntentType.volumeUp);
      expect(parseIntent('音量小一点').type, IntentType.volumeDown);
      final v = parseIntent('音量调到50');
      expect(v.type, IntentType.setVolume);
      expect(v.value, closeTo(0.5, 0.001));
      final v2 = parseIntent('音量20');
      expect(v2.type, IntentType.setVolume);
      expect(v2.value, closeTo(0.2, 0.001));
    });

    test('播报', () {
      final i = parseIntent('播报：开饭了');
      expect(i.type, IntentType.announce);
      expect(i.text, '开饭了');
      final i2 = parseIntent('说，你好');
      expect(i2.type, IntentType.announce);
      expect(i2.text, '你好');
    });

    test('其他', () {
      expect(parseIntent('显示二维码').type, IntentType.showQr);
      expect(parseIntent('你会做什么').type, IntentType.help);
      expect(parseIntent('给我讲个笑话').type, IntentType.unknown);
      expect(parseIntent('').type, IntentType.unknown);
    });

    test('带标点结尾也能识别', () {
      expect(parseIntent('今天天气怎么样？').type, IntentType.weather);
    });
  });
}
