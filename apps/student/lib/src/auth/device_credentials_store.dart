import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/homework.dart';

abstract interface class DeviceCredentialsStore {
  Future<DeviceCredentials?> read();
  Future<void> save(DeviceCredentials credentials);
  Future<void> clear();
}

class SecureDeviceCredentialsStore implements DeviceCredentialsStore {
  SecureDeviceCredentialsStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  static const _deviceKeyName = 'studentDeviceKey';
  static const _baseUrlName = 'studentBaseUrl';
  static const _deviceIdName = 'studentDeviceId';
  static const _childIdName = 'studentChildId';
  static const _childNameName = 'studentChildName';

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<DeviceCredentials?> read() async {
    final preferences = await _preferences();
    final deviceKey = await _secureStorage.read(key: _deviceKeyName);
    final baseUrl = preferences.getString(_baseUrlName);
    final deviceId = preferences.getString(_deviceIdName);
    final childId = preferences.getString(_childIdName);
    final childName = preferences.getString(_childNameName);
    if ([
      deviceKey,
      baseUrl,
      deviceId,
      childId,
      childName,
    ].any((value) => value == null)) {
      return null;
    }
    return DeviceCredentials(
      baseUrl: baseUrl!,
      deviceId: deviceId!,
      deviceKey: deviceKey!,
      childId: childId!,
      childName: childName!,
    );
  }

  @override
  Future<void> save(DeviceCredentials credentials) async {
    final preferences = await _preferences();
    await _secureStorage.write(
      key: _deviceKeyName,
      value: credentials.deviceKey,
    );
    await Future.wait([
      preferences.setString(_baseUrlName, credentials.baseUrl),
      preferences.setString(_deviceIdName, credentials.deviceId),
      preferences.setString(_childIdName, credentials.childId),
      preferences.setString(_childNameName, credentials.childName),
    ]);
  }

  @override
  Future<void> clear() async {
    final preferences = await _preferences();
    await _secureStorage.delete(key: _deviceKeyName);
    await Future.wait([
      preferences.remove(_baseUrlName),
      preferences.remove(_deviceIdName),
      preferences.remove(_childIdName),
      preferences.remove(_childNameName),
    ]);
  }
}
