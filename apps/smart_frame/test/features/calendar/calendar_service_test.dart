import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/calendar/domain/calendar_service.dart';

void main() {
  group('calendarInfoFor', () {
    test('2024-02-10 是春节（正月初一）', () {
      final info = calendarInfoFor(DateTime(2024, 2, 10));
      expect(info.lunarDate, '正月初一');
      expect(info.festivals, contains('春节'));
    });

    test('2026-01-01 是元旦，星期四', () {
      final info = calendarInfoFor(DateTime(2026));
      expect(info.festivals, anyElement(contains('元旦')));
      expect(info.week, '星期四');
    });

    test('干支与生肖', () {
      final info = calendarInfoFor(DateTime(2024, 6, 1));
      expect(info.ganzhiYear, '甲辰');
      expect(info.shengxiao, '龙');
    });

    test('2026-02-04 是立春', () {
      final info = calendarInfoFor(DateTime(2026, 2, 4));
      expect(info.jieqi, '立春');
    });

    test('普通日子的星期正确', () {
      final info = calendarInfoFor(DateTime(2026, 7, 18));
      expect(info.week, '星期六');
      expect(info.festivals, isNot(contains('春节')));
    });
  });
}
