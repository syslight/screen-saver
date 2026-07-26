import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/device_credentials_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(StudentApp(store: SecureDeviceCredentialsStore()));
}
