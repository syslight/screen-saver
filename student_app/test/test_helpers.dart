import 'dart:convert';

import 'package:family_student/src/auth/device_credentials_store.dart';
import 'package:family_student/src/models/homework.dart';
import 'package:http/http.dart' as http;

class MemoryCredentialsStore implements DeviceCredentialsStore {
  MemoryCredentialsStore([this.value]);

  DeviceCredentials? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<DeviceCredentials?> read() async => value;

  @override
  Future<void> save(DeviceCredentials credentials) async => value = credentials;
}

const testCredentials = DeviceCredentials(
  baseUrl: 'http://192.168.1.10:8790',
  deviceId: 'device-1',
  deviceKey: 'secret-device-key',
  childId: 'child-1',
  childName: '大宝',
);

Map<String, dynamic> taskJson({
  String id = 'task-1',
  String title = '数学练习',
  String status = 'pending',
}) => {
  'id': id,
  'title': title,
  'subject': 'math',
  'taskDate': '2026-07-24',
  'dueAt': null,
  'instructions': '完成第 1—6 题',
  'status': status,
  'createdAt': '2026-07-24T10:00:00Z',
  'updatedAt': '2026-07-24T10:00:00Z',
};

http.Response jsonResponse(Object? body, int statusCode) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  statusCode,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
