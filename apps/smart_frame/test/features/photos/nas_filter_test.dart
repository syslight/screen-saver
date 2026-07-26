import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/photos/domain/nas_filter.dart';

void main() {
  // 与 AppConfig.nasFilterKeywords 默认值一致
  const defaultKeywords = ['截图', 'screenshot', '屏幕快照', '收集'];

  group('nasPhotoAllowed', () {
    test('关键词命中路径任意段则排除', () {
      expect(
        nasPhotoAllowed(
          '/photo/收集截图/a.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      expect(
        nasPhotoAllowed(
          '/photo/screenshots/b.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      // 大小写不敏感
      expect(
        nasPhotoAllowed(
          '/Photo/SCREENSHOTS/c.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
    });

    test('常见截图文件名模式命中则排除', () {
      expect(
        nasPhotoAllowed(
          'Screenshot_20240101_123456.png',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      expect(
        nasPhotoAllowed(
          'Screen Shot 2024-01-01 at 12.00.00.png',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      expect(
        nasPhotoAllowed(
          'screencap-123.png',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
    });

    test('普通照片放行', () {
      expect(
        nasPhotoAllowed(
          '/photo/2024春节/IMG_0001.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isTrue,
      );
      expect(
        nasPhotoAllowed('全家福.png', enabled: true, keywords: defaultKeywords),
        isTrue,
      );
    });

    test('enabled 为 false 时全部放行（含截图）', () {
      expect(
        nasPhotoAllowed(
          '/photo/收集截图/a.jpg',
          enabled: false,
          keywords: defaultKeywords,
        ),
        isTrue,
      );
      expect(
        nasPhotoAllowed(
          'Screenshot_20240101_123456.png',
          enabled: false,
          keywords: defaultKeywords,
        ),
        isTrue,
      );
      expect(
        nasPhotoAllowed(
          '/photo/2024春节/IMG_0001.jpg',
          enabled: false,
          keywords: defaultKeywords,
        ),
        isTrue,
      );
    });

    test('空字符串关键词被跳过，普通照片放行', () {
      // 空串若不跳过，lower.contains('') 恒真会把所有文件都排除
      expect(
        nasPhotoAllowed(
          '/photo/2024春节/IMG_0001.jpg',
          enabled: true,
          keywords: [''],
        ),
        isTrue,
      );
    });

    test('自定义 keywords 为替换语义，截图正则独立生效', () {
      // 自定义关键词命中 → 排除
      expect(
        nasPhotoAllowed('/x/自定义目录/d.jpg', enabled: true, keywords: ['自定义']),
        isFalse,
      );
      // 替换语义：默认关键词被整体替换，"截图"不再生效 → 放行
      expect(
        nasPhotoAllowed('/x/截图/e.jpg', enabled: true, keywords: ['自定义']),
        isTrue,
      );
      // 关键词可加回 → 排除
      expect(
        nasPhotoAllowed('/x/截图/e.jpg', enabled: true, keywords: ['自定义', '截图']),
        isFalse,
      );
      // 内置截图正则独立于 keywords，仍命中
      expect(
        nasPhotoAllowed('Screenshot_1.png', enabled: true, keywords: ['自定义']),
        isFalse,
      );
      // 自定义 keywords 不含 screenshot 时，普通目录不受影响
      expect(
        nasPhotoAllowed('/x/普通目录/f.jpg', enabled: true, keywords: ['自定义']),
        isTrue,
      );
    });

    test('@eaDir 段（群晖缩略图目录）排除', () {
      expect(
        nasPhotoAllowed(
          '/photo/@eaDir/IMG.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      expect(
        nasPhotoAllowed(
          '/photo/sub/@eaDir/x/IMG.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isFalse,
      );
      // 子串非独立段不误伤
      expect(
        nasPhotoAllowed(
          '/photo/MyEaDirAlbum/x.jpg',
          enabled: true,
          keywords: defaultKeywords,
        ),
        isTrue,
      );
    });

    test('小文件（size < minBytes）排除，minBytes=0 不限', () {
      expect(
        nasPhotoAllowed(
          '/photo/x.jpg',
          enabled: true,
          keywords: defaultKeywords,
          size: 100,
          minBytes: 30720,
        ),
        isFalse,
      );
      expect(
        nasPhotoAllowed(
          '/photo/x.jpg',
          enabled: true,
          keywords: defaultKeywords,
          size: 50000,
          minBytes: 30720,
        ),
        isTrue,
      );
      expect(
        nasPhotoAllowed(
          '/photo/x.jpg',
          enabled: true,
          keywords: defaultKeywords,
          size: 1,
          minBytes: 0,
        ),
        isTrue,
      );
    });
  });
}
