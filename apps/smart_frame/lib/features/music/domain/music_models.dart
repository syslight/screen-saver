import 'dart:io';

import 'package:smart_frame/features/photos/application/photo_index_service.dart';

enum MusicMood {
  warm('温暖日常'),
  childhood('童年成长'),
  journey('旅行远方'),
  memory('岁月回忆'),
  celebration('欢乐相聚'),
  calm('宁静风景');

  const MusicMood(this.label);
  final String label;
}

class MusicTrack {
  const MusicTrack({
    required this.file,
    required this.title,
    required this.mood,
    this.generated = false,
  });

  final File file;
  final String title;
  final MusicMood mood;
  final bool generated;
}

MusicMood selectMusicMood(PhotoDescription? description, {DateTime? now}) {
  if (description == null) return MusicMood.warm;
  final text = [
    ...description.identities,
    description.location,
    description.caption,
  ].whereType<String>().join('、').toLowerCase();

  if (_hasAny(text, const ['生日', '婚礼', '春节', '新年', '聚会', '庆祝', '派对', '烟花'])) {
    return MusicMood.celebration;
  }
  if (_hasAny(text, const [
    '宝宝',
    '婴儿',
    '童年',
    '儿童',
    '孩子',
    '学校',
    '幼儿园',
    '哥哥',
    '姐姐',
    '弟弟',
    '妹妹',
  ])) {
    return MusicMood.childhood;
  }
  if (description.location != null ||
      _hasAny(text, const ['旅行', '旅游', '远足', '机场', '酒店', '海边', '登山'])) {
    return MusicMood.journey;
  }
  if (_hasAny(text, const ['爷爷', '奶奶', '外公', '外婆', '老照片', '往事', '从前'])) {
    return MusicMood.memory;
  }
  final takenAt = description.takenAt;
  final reference = now ?? DateTime.now();
  if (takenAt != null && takenAt.isBefore(DateTime(reference.year - 15))) {
    return MusicMood.memory;
  }
  if (_hasAny(text, const ['山', '湖', '海', '天空', '日落', '花', '公园', '风景', '夜景'])) {
    return MusicMood.calm;
  }
  return MusicMood.warm;
}

bool _hasAny(String text, List<String> values) =>
    values.any((value) => text.contains(value));
