import 'dart:convert';

import 'package:home_admin/src/api/home_admin_api.dart';
import 'package:home_admin/src/frame/cloud_frame_control_client.dart';
import 'package:home_admin/src/frame/frame_control_client.dart';
import 'package:home_admin/src/models/family_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('云控制器按能力发现节点并读取、切换相片状态', () async {
    var stateRequests = 0;
    final server = parseFamilyServer('https://home.example.com');
    final api = HomeAdminApi(
      server,
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'id': 'hub-1',
                  'name': '家庭主服务器',
                  'status': 'online',
                  'capabilities': [
                    {
                      'type': 'display.photo',
                      'commands': ['frame.get_state', 'frame.command'],
                    },
                  ],
                },
              ]),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['commandName'] == 'frame.get_state') {
          stateRequests += 1;
          return http.Response(
            jsonEncode({
              'success': true,
              'result': {'photo': 'before.jpg', 'photoCount': 2},
              'errorCode': null,
            }),
            200,
          );
        }
        expect(body, {
          'commandName': 'frame.command',
          'arguments': {'action': 'next_photo'},
        });
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'photo': 'after.jpg', 'photoCount': 2},
            'errorCode': null,
          }),
          200,
        );
      }),
    );
    final session = ParentSession(
      server: server,
      token: 'cloud-token',
      expiresAt: DateTime.utc(2030),
      userId: 'user-1',
      householdId: 'home-1',
    );
    final frame = CloudFrameControlClient(api, session);
    addTearDown(frame.dispose);

    await frame.connect();
    expect(frame.connection, FrameConnection.connected);
    expect(frame.state.photo, 'before.jpg');

    frame.send('next_photo');
    for (var i = 0; i < 20 && frame.state.photo != 'after.jpg'; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(frame.state.photo, 'after.jpg');
    expect(stateRequests, 1);
  });
}
