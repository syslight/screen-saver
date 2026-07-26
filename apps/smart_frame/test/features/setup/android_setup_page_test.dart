import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/setup/presentation/android_setup_page.dart';

void main() {
  test('validAgentUrl 只接受带主机的 HTTP(S) 地址', () {
    expect(validAgentUrl('http://192.168.1.9:8790'), isTrue);
    expect(validAgentUrl('https://frame.local'), isTrue);
    expect(validAgentUrl('192.168.1.9:8790'), isFalse);
    expect(validAgentUrl(''), isFalse);
    expect(validAgentUrl('/api'), isFalse);
  });

  test('normalizeAgentUrl 去掉空白和末尾斜杠', () {
    expect(
      normalizeAgentUrl(' http://192.168.1.9:8790/// '),
      'http://192.168.1.9:8790',
    );
  });
}
