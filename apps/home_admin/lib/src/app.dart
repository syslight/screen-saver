import 'package:flutter/material.dart';

import 'api/home_admin_api.dart';
import 'auth/session_store.dart';
import 'frame/cloud_frame_control_client.dart';
import 'frame/frame_control_client.dart';
import 'models/family_server.dart';
import 'screens/frame_dashboard_page.dart';
import 'screens/login_page.dart';

typedef HomeAdminApiBuilder = HomeAdminApi Function(FamilyServer server);
typedef FrameClientBuilder = FrameController Function(ParentSession session);

class HomeAdminApp extends StatefulWidget {
  const HomeAdminApp({
    required this.store,
    this.apiBuilder,
    this.frameClientBuilder,
    super.key,
  });

  final HomeAdminSessionStore store;
  final HomeAdminApiBuilder? apiBuilder;
  final FrameClientBuilder? frameClientBuilder;

  @override
  State<HomeAdminApp> createState() => _HomeAdminAppState();
}

class _HomeAdminAppState extends State<HomeAdminApp> {
  ParentSession? _session;
  FrameController? _frame;
  bool _loading = true;

  HomeAdminApi _api(FamilyServer server) =>
      widget.apiBuilder?.call(server) ?? HomeAdminApi(server);

  FrameController _frameClient(ParentSession session) {
    final custom = widget.frameClientBuilder;
    if (custom != null) return custom(session);
    if (session.server.isCloud) {
      return CloudFrameControlClient(_api(session.server), session);
    }
    return FrameControlClient(session.server.frameWebSocketUrl!);
  }

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final session = await widget.store.read();
    if (!mounted) return;
    _activate(session);
    setState(() => _loading = false);
  }

  void _activate(ParentSession? session) {
    _frame?.dispose();
    _session = session;
    _frame = session == null ? null : _frameClient(session);
    if (_frame != null) _frame!.connect();
  }

  Future<void> _login(
    FamilyServer server,
    String username,
    String password,
  ) async {
    final api = _api(server);
    try {
      final session = await api.login(username, password);
      await widget.store.save(session);
      if (!mounted) return;
      setState(() => _activate(session));
    } finally {
      api.close();
    }
  }

  Future<void> _bootstrap(
    FamilyServer server,
    String householdName,
    String username,
    String password,
  ) async {
    final api = _api(server);
    try {
      await api.bootstrap(
        householdName: householdName,
        username: username,
        password: password,
      );
      final session = await api.login(username, password);
      await widget.store.save(session);
      if (!mounted) return;
      setState(() => _activate(session));
    } finally {
      api.close();
    }
  }

  Future<void> _enroll(FamilyServer server, String code) async {
    final api = _api(server);
    try {
      final session = await api.enroll(
        code,
        deviceName: 'HomeAdmin Android App',
      );
      await widget.store.save(session);
      if (!mounted) return;
      setState(() => _activate(session));
    } finally {
      api.close();
    }
  }

  Future<void> _logout() async {
    final session = _session;
    if (session != null) {
      final api = _api(session.server);
      try {
        await api.logout(session.token);
      } catch (_) {
        // 本地凭据必须可清除，不能因服务器离线把家长锁在旧会话里。
      } finally {
        api.close();
      }
    }
    await widget.store.clear();
    if (!mounted) return;
    setState(() => _activate(null));
  }

  Future<ParentEnrollmentCode> _createEnrollmentCode() async {
    final session = _session;
    if (session == null) {
      throw const HomeAdminApiException('家长会话已失效，请重新登录');
    }
    final api = _api(session.server);
    try {
      return await api.createEnrollmentCode(session.token);
    } finally {
      api.close();
    }
  }

  @override
  void dispose() {
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeAdmin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF315E54)),
        scaffoldBackgroundColor: const Color(0xFFF4F1E9),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
        ),
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _session == null
          ? LoginPage(
              onLogin: _login,
              onBootstrap: _bootstrap,
              onEnroll: _enroll,
            )
          : FrameDashboardPage(
              server: _session!.server,
              frame: _frame!,
              token: _session!.token,
              apiBuilder: _api,
              onCreateEnrollmentCode: _createEnrollmentCode,
              onLogout: _logout,
            ),
    );
  }
}
