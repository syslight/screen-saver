import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_frame/features/remote_control/domain/protocol.dart';

void main() {
  group('decodeCommand', () {
    test('合法指令', () {
      final cmd = decodeCommand('{"type":"command","action":"next_photo"}');
      expect(cmd.action, 'next_photo');
      expect(cmd.text, isNull);
      expect(cmd.value, isNull);
    });

    test('带参数的指令', () {
      final cmd = decodeCommand(
        '{"type":"command","action":"set_volume","value":0.5}',
      );
      expect(cmd.action, 'set_volume');
      expect(cmd.value, 0.5);

      final cmd2 = decodeCommand(
        '{"type":"command","action":"announce","text":"你好"}',
      );
      expect(cmd2.text, '你好');
    });

    test('非法输入抛 FormatException', () {
      expect(() => decodeCommand('not json'), throwsFormatException);
      expect(() => decodeCommand('[1,2]'), throwsFormatException);
      expect(() => decodeCommand('{"type":"state"}'), throwsFormatException);
      expect(() => decodeCommand('{"type":"command"}'), throwsFormatException);
    });
  });

  group('encode', () {
    test('encodeState', () {
      final s =
          jsonDecode(encodeState({'photo': 'a.jpg', 'volume': 0.8}))
              as Map<String, dynamic>;
      expect(s['type'], 'state');
      expect(s['photo'], 'a.jpg');
      expect(s['volume'], 0.8);
    });

    test('encodeEvent', () {
      final e = jsonDecode(encodeEvent('已切换')) as Map<String, dynamic>;
      expect(e['type'], 'event');
      expect(e['message'], '已切换');
    });
  });
}
