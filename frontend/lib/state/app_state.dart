import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import '../services/api.dart';

/// What the app knows about the signed-in user. The server (PostgreSQL on Neon) is the source of truth;
/// the device keeps the log-in token and a copy of the profile so the app still opens without internet.
class AppState extends ChangeNotifier {
  AppState({Api? api}) : api = api ?? Api();

  static const _tokenKey = 'token_v1';
  static const _profileKey = 'profile_v1';

  final Api api;
  Profile? profile;
  bool loaded = false;
  bool get signedIn => api.token != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    final cached = prefs.getString(_profileKey);
    if (cached != null) profile = Profile.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    if (signedIn) {
      try {
        final remote = await api.getProfile();
        if (remote != null) await _cache(Profile.fromJson(remote));
      } on ApiException catch (e) {
        if (e.isUnauthorised) await signOut();   // token expired or account deleted
        // Offline: keep the cached copy.
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> signIn(String email, String password, {required bool newAccount}) async {
    newAccount ? await api.register(email, password) : await api.login(email, password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
    profile = null;
    final remote = await api.getProfile();
    if (remote != null) {
      await _cache(Profile.fromJson(remote));
    } else {
      await prefs.remove(_profileKey);
    }
    notifyListeners();
  }

  Future<void> signOut() async {
    api.token = null;
    profile = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
    notifyListeners();
  }

  /// Save to the server first; only then update the device copy.
  Future<void> saveProfile(Profile p) async {
    await api.putProfile(p.toJson());
    await _cache(p);
    notifyListeners();
  }

  Future<void> _cache(Profile p) async {
    profile = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(p.toJson()));
  }
}
