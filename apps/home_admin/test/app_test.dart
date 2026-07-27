import 'package:home_admin/src/app.dart';
import 'package:home_admin/src/auth/session_store.dart';
import 'package:home_admin/src/models/family_server.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySessionStore implements HomeAdminSessionStore {
  ParentSession? session;

  @override
  Future<void> clear() async => session = null;

  @override
  Future<ParentSession?> read() async => session;

  @override
  Future<void> save(ParentSession value) async => session = value;
}

void main() {
  testWidgets('无家长会话时显示单一家庭服务器登录页', (tester) async {
    await tester.pumpWidget(HomeAdminApp(store: _MemorySessionStore()));
    await tester.pumpAndSettle();

    expect(find.text('HomeAdmin'), findsOneWidget);
    expect(find.text('家庭服务器地址'), findsOneWidget);
    expect(find.text('家长账号'), findsOneWidget);
    expect(find.text('登录家庭服务器'), findsOneWidget);
    expect(find.text('使用一次性绑定码连接云平台'), findsOneWidget);
    expect(find.text('第一次使用？初始化家庭'), findsOneWidget);
  });
}
