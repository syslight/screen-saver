import 'dart:convert';
import 'dart:io';

import 'package:family_student/src/api/student_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

import 'test_helpers.dart';

void main() {
  group('normalizeServerUrl', () {
    test('adds http and removes a trailing slash', () {
      expect(
        normalizeServerUrl(' 192.168.1.10:8790/ '),
        'http://192.168.1.10:8790',
      );
      expect(
        normalizeServerUrl('https://home.example'),
        'https://home.example',
      );
    });

    test('rejects paths, queries and unsupported schemes', () {
      for (final value in [
        '',
        'ftp://192.168.1.10',
        'http://192.168.1.10/parent',
        'http://192.168.1.10?token=x',
      ]) {
        expect(() => normalizeServerUrl(value), throwsFormatException);
      }
    });
  });

  test('parses task status without exposing parent-only fields', () async {
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Student secret-device-key');
      return jsonResponse([taskJson(status: 'needs_parent_review')], 200);
    });
    final api = StudentApi(
      baseUrl: testCredentials.baseUrl,
      deviceKey: testCredentials.deviceKey,
      client: client,
    );
    final tasks = await api.listTasks();
    expect(tasks.single.title, '数学练习');
    expect(tasks.single.statusLabel, '等待家长检查');
  });

  test('pairs with JSON and maps structured API errors', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        expect(request.url.path, '/api/v1/student/pair');
        expect(jsonDecode(request.body)['code'], 'one-time');
        return jsonResponse({
          'deviceId': 'device-1',
          'deviceKey': 'device-key',
          'childId': 'child-1',
          'childName': '大宝',
        }, 201);
      }
      return jsonResponse({
        'code': 'invalid_student_device',
        'message': '设备已撤销',
      }, 401);
    });
    final api = StudentApi(baseUrl: testCredentials.baseUrl, client: client);
    final credentials = await api.pair(code: 'one-time', deviceName: '学习平板');
    expect(credentials.childName, '大宝');
    await expectLater(
      api.me(),
      throwsA(
        isA<StudentApiException>()
            .having((error) => error.isUnauthorized, 'isUnauthorized', isTrue)
            .having((error) => error.message, 'message', '设备已撤销'),
      ),
    );
  });

  test('submits each photo with the files multipart field', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'student-api-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final first = File('${temporary.path}/one.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final second = File('${temporary.path}/two.jpg')
      ..writeAsBytesSync([4, 5, 6]);
    late String body;
    final client = MockClient((request) async {
      body = request.body;
      return jsonResponse({
        'id': 'submission-1',
        'taskId': 'task-1',
        'attemptNo': 1,
        'status': 'needs_parent_review',
        'submittedAt': '2026-07-24T11:00:00Z',
        'assetCount': 2,
        'reviews': <dynamic>[],
      }, 201);
    });
    final api = StudentApi(
      baseUrl: testCredentials.baseUrl,
      deviceKey: testCredentials.deviceKey,
      client: client,
    );
    final submission = await api.submit('task-1', [
      XFile(first.path),
      XFile(second.path),
    ]);
    expect(submission.assetCount, 2);
    expect('name="files"'.allMatches(body), hasLength(2));
    expect(body, contains('filename="one.jpg"'));
    expect(body, contains('filename="two.jpg"'));
  });
}
