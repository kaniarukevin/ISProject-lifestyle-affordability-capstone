import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';

/// Holds what the user has entered and keeps it on the device, so nothing personal
/// leaves the phone except the numbers sent to the backend for a calculation.
class AppState extends ChangeNotifier {
  static const _profileKey = 'profile_v1';

  Profile? profile;
  bool loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileKey);
    if (raw != null) {
      profile = Profile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> saveProfile(Profile p) async {
    profile = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(p.toJson()));
    notifyListeners();
  }
}
