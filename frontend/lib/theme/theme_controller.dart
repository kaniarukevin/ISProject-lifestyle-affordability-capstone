import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light, dark or System (follow the device setting). Chosen on the You screen and remembered on this device.
class ThemeController extends ChangeNotifier {
  static const _key = 'theme_mode_v1';

  ThemeMode mode = ThemeMode.light;

  static ThemeMode parse(String? s) => switch (s) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode = parse(prefs.getString(_key));
    notifyListeners();
  }

  Future<void> set(ThemeMode m) async {
    mode = m;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, m.name);
  }
}
