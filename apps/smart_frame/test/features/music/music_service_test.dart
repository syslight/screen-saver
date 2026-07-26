import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/music/application/music_service.dart';
import 'package:smart_frame/features/music/domain/music_models.dart';
import 'package:smart_frame/features/photos/application/photo_index_service.dart';

void main() {
  group('照片情境配乐', () {
    test('家庭身份、地点和事件映射为稳定音乐主题', () {
      expect(
        selectMusicMood(
          const PhotoDescription(photoId: '1', identities: ['弟弟']),
        ),
        MusicMood.childhood,
      );
      expect(
        selectMusicMood(
          const PhotoDescription(photoId: '2', caption: '家人庆祝生日'),
        ),
        MusicMood.celebration,
      );
      expect(
        selectMusicMood(
          const PhotoDescription(photoId: '3', location: '广州动物园'),
        ),
        MusicMood.journey,
      );
      expect(
        selectMusicMood(
          PhotoDescription(
            photoId: '4',
            takenAt: DateTime(1998),
            caption: '一张旧照片',
          ),
          now: DateTime(2026),
        ),
        MusicMood.memory,
      );
    });

    test('夜间静音支持跨午夜区间', () {
      expect(
        isMusicQuietHour(DateTime(2026, 7, 26, 23), startHour: 22, endHour: 8),
        isTrue,
      );
      expect(
        isMusicQuietHour(DateTime(2026, 7, 26, 7), startHour: 22, endHour: 8),
        isTrue,
      );
      expect(
        isMusicQuietHour(DateTime(2026, 7, 26, 12), startHour: 22, endHour: 8),
        isFalse,
      );
    });
  });
}
