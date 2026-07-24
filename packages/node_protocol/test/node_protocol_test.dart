import 'dart:convert';
import 'dart:io';

import 'package:node_protocol/node_protocol.dart';
import 'package:test/test.dart';

void main() {
  final fixtures =
      jsonDecode(File('fixtures/messages.json').readAsStringSync())
          as Map<String, Object?>;

  test('all canonical valid messages round trip', () {
    final messages = fixtures['valid']! as List<Object?>;
    for (final message in messages.cast<Map<String, Object?>>()) {
      final parsed = NodeEnvelope.fromJson(message);
      expect(NodeEnvelope.decode(parsed.encode()).type, parsed.type);
    }
  });

  test('all canonical invalid messages return the expected code', () {
    final fixturesList = fixtures['invalid']! as List<Object?>;
    for (final fixture in fixturesList.cast<Map<String, Object?>>()) {
      final message = fixture['message']! as Map<String, Object?>;
      expect(
        () => NodeEnvelope.fromJson(message),
        throwsA(
          isA<ProtocolException>().having(
            (error) => error.code,
            'code',
            fixture['code'],
          ),
        ),
      );
    }
  });
}
