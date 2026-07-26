import 'dart:io';

import 'package:family_student/src/api/student_api.dart';
import 'package:family_student/src/app.dart';
import 'package:family_student/src/screens/homework_home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

import 'test_helpers.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 50; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  testWidgets(
    'unpaired tablet completes pairing and opens empty homework list',
    (tester) async {
      final store = MemoryCredentialsStore();
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/student/pair') {
          return jsonResponse({
            'deviceId': 'device-1',
            'deviceKey': 'secret-device-key',
            'childId': 'child-1',
            'childName': '大宝',
          }, 201);
        }
        if (request.url.path == '/api/v1/student/homework/tasks') {
          return http.Response('[]', 200);
        }
        return http.Response('not found', 404);
      });
      await tester.pumpWidget(
        StudentApp(
          store: store,
          apiBuilder: (baseUrl, deviceKey) => StudentApi(
            baseUrl: baseUrl,
            deviceKey: deviceKey,
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接家庭学习助手'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('serverField')),
        '192.168.1.10:8790',
      );
      await tester.enterText(
        find.byKey(const Key('pairingCodeField')),
        'one-time-code',
      );
      await tester.tap(find.byKey(const Key('pairButton')));
      await tester.pumpAndSettle();
      expect(store.value?.childName, '大宝');
      expect(find.text('大宝的作业'), findsOneWidget);
      expect(find.byKey(const Key('emptyTasks')), findsOneWidget);
    },
  );

  testWidgets('failed submission keeps captured photos for retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final temporary = Directory.systemTemp.createTempSync(
      'student-widget-test-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final image = File('${temporary.path}/page.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/student/homework/tasks') {
        return jsonResponse([taskJson(status: 'in_progress')], 200);
      }
      if (request.url.path == '/api/v1/student/homework/tasks/task-1') {
        return jsonResponse(taskJson(status: 'in_progress'), 200);
      }
      if (request.url.path.endsWith('/submissions') &&
          request.method == 'GET') {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/submissions') &&
          request.method == 'POST') {
        return jsonResponse({
          'code': 'upload_failed',
          'message': '上传失败，请稍后重试',
        }, 500);
      }
      return http.Response('not found', 404);
    });
    final api = StudentApi(
      baseUrl: testCredentials.baseUrl,
      deviceKey: testCredentials.deviceKey,
      client: client,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeworkHomePage(
          credentials: testCredentials,
          api: api,
          capturePhoto: () async => XFile(image.path),
          photoPreviewBuilder: (_) => const ColoredBox(color: Colors.blue),
          onCredentialsInvalid: () async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.byKey(const Key('task-task-1')));
    await tester.tap(find.byKey(const Key('task-task-1')));
    await pumpUntilFound(tester, find.byKey(const Key('capturePhotoButton')));
    await tester.tap(find.byKey(const Key('capturePhotoButton')));
    await pumpUntilFound(tester, find.text('拍一页（1/6）'));
    expect(find.text('拍一页（1/6）'), findsOneWidget);
    final submitButton = find.byKey(const Key('submitHomeworkButton'));
    await tester.ensureVisible(submitButton);
    await tester.pump();
    final button = tester.widget<FilledButton>(submitButton);
    expect(button.onPressed, isNotNull);
    await tester.runAsync(() async {
      button.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpUntilFound(tester, find.text('上传失败，请稍后重试'));
    expect(find.text('上传失败，请稍后重试'), findsOneWidget);
    expect(find.text('拍一页（1/6）'), findsOneWidget);
    expect(find.byKey(const Key('removePhoto-0')), findsOneWidget);
    await tester.pageBack();
    await pumpUntilFound(tester, find.byKey(const Key('task-task-1')));
  });

  testWidgets('401 removes local device credentials', (tester) async {
    final store = MemoryCredentialsStore(testCredentials);
    final client = MockClient(
      (_) async => jsonResponse({
        'code': 'invalid_student_device',
        'message': '设备已撤销',
      }, 401),
    );
    await tester.pumpWidget(
      StudentApp(
        store: store,
        apiBuilder: (baseUrl, deviceKey) =>
            StudentApi(baseUrl: baseUrl, deviceKey: deviceKey, client: client),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.text('连接家庭学习助手'), findsOneWidget);
  });
}
