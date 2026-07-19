import 'package:lunar/lunar.dart';

/// 某一天的日历信息（公历 + 农历 + 节气 + 节日）。
class CalendarInfo {
  const CalendarInfo({
    required this.ganzhiYear,
    required this.shengxiao,
    required this.lunarDate,
    required this.week,
    this.jieqi,
    required this.festivals,
  });

  /// 干支年，如"甲辰"
  final String ganzhiYear;

  /// 生肖，如"龙"
  final String shengxiao;

  /// 农历月日，如"冬月廿三"
  final String lunarDate;

  /// 星期，如"星期五"
  final String week;

  /// 当天节气（无则 null）
  final String? jieqi;

  /// 当天节日列表（公历 + 农历）
  final List<String> festivals;
}

CalendarInfo calendarInfoFor(DateTime date) {
  final solar = Solar.fromYmd(date.year, date.month, date.day);
  final lunar = solar.getLunar();
  final jieqi = lunar.getJieQi();
  return CalendarInfo(
    ganzhiYear: lunar.getYearInGanZhi(),
    shengxiao: lunar.getYearShengXiao(),
    lunarDate: '${lunar.getMonthInChinese()}月${lunar.getDayInChinese()}',
    week: '星期${solar.getWeekInChinese()}',
    jieqi: jieqi.isEmpty ? null : jieqi,
    festivals: [
      ...solar.getFestivals(),
      ...lunar.getFestivals(),
      ...solar.getOtherFestivals(),
      ...lunar.getOtherFestivals(),
    ],
  );
}
