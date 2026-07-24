import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/ui/android_setup_page.dart';

void main() {
  test('validComputeNodeUrl 只接受带主机的 HTTP(S) 地址', () {
    expect(validComputeNodeUrl('http://192.168.1.9:8780'), isTrue);
    expect(validComputeNodeUrl('https://frame.local'), isTrue);
    expect(validComputeNodeUrl('192.168.1.9:8780'), isFalse);
    expect(validComputeNodeUrl(''), isFalse);
    expect(validComputeNodeUrl('/api'), isFalse);
  });

  test('normalizeComputeNodeUrl 去掉空白和末尾斜杠', () {
    expect(
      normalizeComputeNodeUrl(' http://192.168.1.9:8780/// '),
      'http://192.168.1.9:8780',
    );
  });
}
