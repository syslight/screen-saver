import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/session_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(HomeAdminApp(store: SecureHomeAdminSessionStore()));
}
