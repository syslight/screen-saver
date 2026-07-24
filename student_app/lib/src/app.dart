import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api/student_api.dart';
import 'auth/device_credentials_store.dart';
import 'models/homework.dart';
import 'screens/homework_home_page.dart';
import 'screens/pairing_page.dart';

typedef StudentApiBuilder =
    StudentApi Function(String baseUrl, String? deviceKey);
typedef CapturePhoto = Future<XFile?> Function();
typedef PhotoPreviewBuilder = Widget Function(XFile photo);

class StudentApp extends StatefulWidget {
  const StudentApp({
    required this.store,
    this.apiBuilder,
    this.capturePhoto,
    this.photoPreviewBuilder,
    super.key,
  });

  final DeviceCredentialsStore store;
  final StudentApiBuilder? apiBuilder;
  final CapturePhoto? capturePhoto;
  final PhotoPreviewBuilder? photoPreviewBuilder;

  @override
  State<StudentApp> createState() => _StudentAppState();
}

class _StudentAppState extends State<StudentApp> {
  DeviceCredentials? _credentials;
  var _loading = true;

  StudentApi _buildApi(String baseUrl, String? deviceKey) =>
      widget.apiBuilder?.call(baseUrl, deviceKey) ??
      StudentApi(baseUrl: baseUrl, deviceKey: deviceKey);

  Future<XFile?> _capturePhoto() =>
      widget.capturePhoto?.call() ??
      ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
        maxWidth: 2400,
      );

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final credentials = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _credentials = credentials;
      _loading = false;
    });
  }

  Future<void> _paired(DeviceCredentials credentials) async {
    await widget.store.save(credentials);
    if (!mounted) return;
    setState(() => _credentials = credentials);
  }

  Future<void> _forgetCredentials() async {
    await widget.store.clear();
    if (!mounted) return;
    setState(() => _credentials = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      key: ValueKey(_credentials?.deviceId ?? 'unpaired'),
      title: '家庭学习助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E725B),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F1E9),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _credentials == null
          ? PairingPage(apiBuilder: _buildApi, onPaired: _paired)
          : HomeworkHomePage(
              credentials: _credentials!,
              api: _buildApi(_credentials!.baseUrl, _credentials!.deviceKey),
              capturePhoto: _capturePhoto,
              photoPreviewBuilder: widget.photoPreviewBuilder,
              onCredentialsInvalid: _forgetCredentials,
            ),
    );
  }
}
