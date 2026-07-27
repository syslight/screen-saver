import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/family_server.dart';

abstract interface class HomeAdminSessionStore {
  Future<ParentSession?> read();
  Future<void> save(ParentSession session);
  Future<void> clear();
}

class SecureHomeAdminSessionStore implements HomeAdminSessionStore {
  SecureHomeAdminSessionStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  static const _tokenKey = 'homeAdminSessionToken';
  static const _sessionKey = 'homeAdminSessionMetadata';

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<ParentSession?> read() async {
    final token = await _secureStorage.read(key: _tokenKey);
    final metadata = (await _preferences()).getString(_sessionKey);
    if (token == null || metadata == null) return null;
    try {
      final json = jsonDecode(metadata) as Map<String, dynamic>;
      final session = ParentSession(
        server: FamilyServer.fromJson(json['server'] as Map<String, dynamic>),
        token: token,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        userId: json['userId'] as String,
        householdId: json['householdId'] as String,
      );
      if (session.expired) {
        await clear();
        return null;
      }
      return session;
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(ParentSession session) async {
    await _secureStorage.write(key: _tokenKey, value: session.token);
    await (await _preferences()).setString(
      _sessionKey,
      jsonEncode({
        'server': session.server.toJson(),
        'expiresAt': session.expiresAt.toIso8601String(),
        'userId': session.userId,
        'householdId': session.householdId,
      }),
    );
  }

  @override
  Future<void> clear() async {
    await _secureStorage.delete(key: _tokenKey);
    await (await _preferences()).remove(_sessionKey);
  }
}
